internal import CMinizip
import Foundation

extension NativeArchive {
    /// CD payloads have a separate fixed memory budget; they are not ordinary file payloads.
    borrowing func prepareCatalog(password: String?, limits: ZIPLimits, cancellation: ArchiveCancellation?) throws {
        var count: UInt64 = 0
        let status = magiczip_catalog_info(pointer, &count)
        guard let password else {
            guard status == -107 else {
                if status == 0 {
                    throw ZIPError.unsupported(path: nil, feature: "Encrypted catalog: use SecureZIPReader")
                }
                try check(status, "inspect catalog")
                return
            }
            return
        }
        guard status != -107 else {
            throw ZIPError.unsupported(path: nil, feature: "Expected a minizip-ng encrypted catalog")
        }
        try check(status, "inspect encrypted catalog")
        guard count <= limits.maximumEntries else {
            throw ZIPError.limitExceeded("Catalog entry count")
        }
        var info = magiczip_info()
        try check(magiczip_metadata(pointer, &info), "read catalog metadata")
        guard info.uncompressed_size >= 0, info.compressed_size >= 28 else {
            throw ZIPError.backend(operation: "validate catalog size", path: nil, status: -103)
        }
        guard info.uncompressed_size <= 64 * 1024 * 1024 else {
            throw ZIPError.limitExceeded("Catalog bytes")
        }
        try withPassword(password) { password in
            try check(magiczip_read_open(pointer, password), "open encrypted catalog")
            var complete = false
            try completing {
                var total: Int64 = 0
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    try checkCancellation(cancellation)
                    let size = magiczip_read(pointer, &buffer, Int32(buffer.count))
                    if size < 0 {
                        try check(size, "read encrypted catalog")
                    }
                    if size == 0 {
                        break
                    }
                    guard Int64(size) <= info.uncompressed_size - total else {
                        throw ZIPError.limitExceeded("Catalog bytes")
                    }
                    total += Int64(size)
                    try check(magiczip_catalog_append(pointer, &buffer, size), "buffer encrypted catalog")
                }
                complete = true
            } cleanup: {
                try check(magiczip_read_close(pointer, complete ? 1 : 0), "authenticate/close catalog")
            }
        }
        // Never expose metadata to the scanner or caller before HMAC and size verification succeed.
        try checkCancellation(cancellation)
        try check(magiczip_catalog_install(pointer, count), "install authenticated catalog")
    }

    borrowing func writeCatalog(password: String, cancellation: ArchiveCancellation?) throws {
        try withPassword(password) { password in
            var length: Int32 = 0
            try check(magiczip_catalog_write_begin(pointer, password, &length), "open output catalog")
            try completing {
                var offset: Int32 = 0
                while offset < length {
                    try checkCancellation(cancellation)
                    let size = min(64 * 1024, length - offset)
                    try check(magiczip_catalog_write_chunk(pointer, offset, size), "write output catalog")
                    offset += size
                }
                try check(magiczip_catalog_write_end(pointer), "finalize output catalog")
            } cleanup: {
                // Keep borrowed password storage alive through closure, including error paths.
                try check(magiczip_write_close(pointer), "close output catalog")
            }
        }
    }
}
