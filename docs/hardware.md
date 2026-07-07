# Hardware Recommendations

Initial block download (IBD) is CPU-bound. The dominant cost is SHA-256 hashing — used for block hashes, transaction IDs, merkle roots, sighash computation, and script verification. The node uses **Bitcoin Core's multi-backend SHA-256** with runtime CPU detection, automatically selecting the best available implementation:

| Backend | CPUs | Speedup vs generic |
|---------|------|--------------------|
| **SHA-NI** | AMD Zen 1+ (2017+), Intel Ice Lake+ (2019+) | ~5x |
| **AVX2 8-way** | Intel Haswell+ (2013+), AMD Excavator+ (2015+) | ~2-3x |
| **SSE4.1 4-way** | Intel Penryn+ (2008+), AMD Bulldozer+ (2011+) | ~1.5x |
| **ARMv8 crypto** | Apple Silicon, AWS Graviton, ARM Cortex-A72+ | ~5x |
| **Generic scalar** | Everything else | 1x (baseline) |

The node logs which backend was selected at startup (e.g., `SHA-256 backend: sse4(1way),avx2(8way)`).

**Recommended (fast IBD):**

| Component | Recommendation | Why |
|-----------|---------------|-----|
| CPU | AMD Ryzen/EPYC (Zen 1+) or Intel 10th gen+ | SHA-NI hardware acceleration. This is the single biggest factor for sync speed |
| RAM | 8 GB+ | Allows `--dbcache=4096` for fewer UTXO flushes during IBD |
| Storage | SSD (NVMe preferred) | Block reads are ~29% of sync time; HDD will bottleneck |
| Network | 50+ Mbps | Block download from 8 peers saturates slower connections |

**CPU matters most.** SHA-NI is fastest, but AVX2 CPUs (like Intel Haswell Xeons) now get the 8-way parallel backend instead of falling back to generic scalar:

- **With SHA-NI** (AMD Zen 1+ / Intel Ice Lake+): Full mainnet IBD in ~8-12 hours
- **With AVX2** (Intel Haswell/Broadwell/Skylake): ~1.5-2x slower than SHA-NI, but ~2-3x faster than generic
- **Generic only** (very old CPUs): IBD takes 3-5x longer than SHA-NI

You can check your CPU's capabilities:
```bash
# Linux
grep -oE 'sha_ni|avx2|sse4_1' /proc/cpuinfo | sort -u

# macOS (Apple Silicon always has hardware SHA-256 via ARM crypto extensions)
sysctl -a | grep hw.optional.armv8_2_sha
```

**Budget options:** A $5-10/month AMD EPYC VPS (Hetzner, Vultr, etc.) will sync mainnet fastest due to SHA-NI. But older Haswell/Broadwell Xeon servers now perform well too with the AVX2 backend.

**Minimum viable:** Any 64-bit x86 or ARM machine with 2+ GB RAM and 50+ GB disk will work — just slower. Use `--dbcache=256` on memory-constrained machines. Signet and testnet sync in minutes regardless of hardware.

