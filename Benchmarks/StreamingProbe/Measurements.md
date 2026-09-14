# Streaming measurements: 2026-09-11

Historical results from the registry and streaming changes, preserved with their comparison method. These figures describe that local run, not the current checkout. For new comparisons, see [Benchmarks](../README.md).

## Reproducing Release measurements

`PerformanceProbe` uses a real file through `add(file:)`, public reads, full extraction and 2,000 small files. Each sample is a fresh process and reports wall time, application peak RSS and summed malloc-zone high-water/live-block statistics. Compiler memory is excluded. The driver uses the same deterministic 128 MiB file, alternating 64 KiB zero and seeded random blocks, and 2,000 files of 1 KiB. Compression is Store or Deflate level 6, plaintext or AES-256. Writes and extraction include the normal fsync/close checks. File caches are not flushed. Each comparison uses three alternating samples, except the isolated CRC comparison, which uses five.

```sh
mise exec -- swift build -c release --package-path Benchmarks/StreamingProbe
python3 Benchmarks/StreamingProbe/compare.py /absolute/baseline/StreamingProbe \
  "$PWD/Benchmarks/StreamingProbe/.build/release/StreamingProbe"
# Same Swift code, with only the original duplicate-CRC adapter in the first binary:
python3 Benchmarks/StreamingProbe/compare.py /absolute/duplicate-crc/StreamingProbe \
  "$PWD/Benchmarks/StreamingProbe/.build/release/StreamingProbe" --crc
```

Build the baseline from `e50f984` in a separate checkout, copy the comparison probe's Swift files there, and compile it with `-c release -Xswiftc -DBASELINE` (only selects the old limits API). If that checkout's directory is not named MagicZip, use an explicit `name: "MagicZip"` on its local package dependency. Both C and Swift must be Release. One prerequisite correction is applied equally to both versions: the Store+AES raw-codec rebinding after authentication. Unmodified e50f984 fails Store+AES read/close with status -1, so it cannot supply a successful baseline for that matrix cell. This baseline adjustment does not remove integrity checks.

The updated adapter in this comparison uses the upstream running CRC through patch 0003 and still compares it for plaintext/AE-1. The accessor avoids upstream's close-time compressed-size gate, which cannot replace the adapter check for AES. AE-2 HMAC and all size checks remain. Independent corrupt CRC/HMAC cases remain rejected. No experimental non-verifying benchmark backend ships.

## Measurements on 2026-09-11

Local Apple Silicon arm64, macOS 26.6.2, Apple Swift 6.2.4 / Xcode 26.3, with both Swift and C built in Release mode. Times are median [minimum–maximum], in seconds, over three fresh processes. RSS is the maximum of the three application peaks, in MiB. Baseline is e50f984 plus the identical Store+AES close correction described above.

| Workload | Operation | Before, seconds | After, seconds | Peak RSS before → after, MiB |
| --- | --- | ---: | ---: | ---: |
| 2000 | paths | 0.4221 [0.4207–0.4426] | 0.0026 [0.0025–0.0027] | 21.2 → 7.1 |
| 4000 | paths | 1.6961 [1.6674–1.7036] | 0.0039 [0.0039–0.0044] | 60.1 → 7.7 |
| 8000 | paths | 6.8005 [6.7404–6.9675] | 0.0070 [0.0070–0.0071] | 216.3 → 8.2 |
| write-store | write | 0.1292 [0.0823–0.1546] | 0.1007 [0.0996–0.1090] | 7.0 → 6.7 |
| write-store | read | 0.0186 [0.0183–0.0195] | 0.0149 [0.0148–0.0153] | 6.9 → 6.8 |
| write-store | extract | 0.0551 [0.0551–0.0563] | 0.0501 [0.0479–0.0671] | 6.9 → 6.8 |
| tree-store | tree | 0.2410 [0.2377–0.2781] | 0.2169 [0.2102–0.2231] | 8.5 → 8.2 |
| tree-store | read | 0.2661 [0.2584–0.2678] | 0.2529 [0.2503–0.2561] | 8.0 → 7.7 |
| tree-store | extract | 0.4364 [0.4341–0.4422] | 0.4451 [0.4390–0.4712] | 8.1 → 7.8 |
| write-deflate | write | 1.0086 [0.9699–1.0369] | 1.0161 [0.9988–1.0871] | 7.4 → 7.1 |
| write-deflate | read | 0.0622 [0.0607–0.0659] | 0.0571 [0.0562–0.0572] | 7.0 → 7.0 |
| write-deflate | extract | 0.0992 [0.0980–0.1069] | 0.0976 [0.0957–0.0995] | 7.0 → 6.9 |
| tree-deflate | tree | 0.2481 [0.2461–0.2709] | 0.2488 [0.2476–0.2946] | 9.1 → 8.8 |
| tree-deflate | read | 0.2758 [0.2579–0.2814] | 0.2792 [0.2582–0.3279] | 8.0 → 7.8 |
| tree-deflate | extract | 0.4735 [0.4550–0.5139] | 0.4658 [0.4456–0.4931] | 8.0 → 7.9 |
| write-store-aes | write | 0.3447 [0.3255–0.3648] | 0.3042 [0.3007–0.3132] | 7.2 → 6.8 |
| write-store-aes | read | 0.2220 [0.2172–0.2275] | 0.2099 [0.2092–0.2102] | 7.0 → 7.0 |
| write-store-aes | extract | 0.2681 [0.2521–0.2903] | 0.2529 [0.2450–0.2689] | 7.0 → 6.9 |
| tree-store-aes | tree | 2.4341 [2.4113–2.5146] | 2.3295 [2.3172–2.3649] | 8.9 → 8.7 |
| tree-store-aes | read | 2.4580 [2.3817–2.4671] | 2.3741 [2.3477–2.3802] | 8.1 → 7.9 |
| tree-store-aes | extract | 2.5970 [2.5592–2.6410] | 2.6307 [2.5933–2.7155] | 8.3 → 8.0 |
| write-deflate-aes | write | 1.1442 [1.1121–1.1511] | 1.1405 [1.0894–1.1777] | 7.4 → 7.1 |
| write-deflate-aes | read | 0.1669 [0.1604–0.1670] | 0.1566 [0.1556–0.1627] | 7.0 → 7.1 |
| write-deflate-aes | extract | 0.2034 [0.2024–0.2124] | 0.2057 [0.1978–0.2079] | 7.0 → 7.1 |
| tree-deflate-aes | tree | 2.4576 [2.4237–2.5021] | 2.4100 [2.3861–2.4160] | 9.5 → 9.2 |
| tree-deflate-aes | read | 2.3886 [2.3382–2.4554] | 2.3670 [2.3391–2.4136] | 8.4 → 8.1 |
| tree-deflate-aes | extract | 2.6740 [2.6629–2.7072] | 2.6545 [2.6020–2.7209] | 8.3 → 8.3 |

`2000/4000/8000` count parent components plus a final file name in a Python-created ZIP. `write-*` is the real 128 MiB file, and `tree-*` is 2,000 files. Metadata scans show the expected linear scaling after the registry change. Streaming timings include filesystem noise. These runs do not establish a general write/extraction speedup, particularly for the small-file workload. The optimization removes specific allocation/copy sites while retaining bounded memory and all checks.

The allocator returned zero for summed `max_size_in_use`, so heap high-water was unavailable. End-of-operation live-block counts are not total allocation counts. No allocation-profiler measurement was recorded.

Isolated CRC comparison (same Swift implementation, duplicate CRC vs patched accessor), five runs over the same 128 MiB file:

| Read variant | Duplicate CRC, seconds median [min–max] | Single CRC, seconds median [min–max] |
| --- | ---: | ---: |
| store | 0.0177 [0.0176–0.0232] | 0.0149 [0.0146–0.0154] |
| deflate | 0.0604 [0.0596–0.0622] | 0.0565 [0.0559–0.0624] |
| store-aes | 0.2139 [0.2110–0.2251] | 0.2153 [0.2075–0.2216] |
| deflate-aes | 0.1579 [0.1573–0.1637] | 0.1546 [0.1539–0.1761] |

Store read median improved about 16%, while AES differences overlap noise. The accessor preserved checksum verification while avoiding a duplicate CRC update.
