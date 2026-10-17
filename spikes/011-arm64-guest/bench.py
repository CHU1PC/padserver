import time, hashlib, platform, zlib

def loop():
    s = 0
    for i in range(2000000):
        s += i * i % 7
    return s

def md5():
    h = hashlib.md5()
    b = bytes(1 << 20)
    for _ in range(8):
        h.update(b)
    return h.hexdigest()

def zl():
    d = bytes(range(256)) * 4096
    for _ in range(4):
        zlib.decompress(zlib.compress(d, 6))

print("ARCH", platform.machine(), flush=True)
for name, fn in (("loop2M", loop), ("md5_8MiB", md5), ("zlib_4MiBx4", zl)):
    for n in range(5):
        t = time.perf_counter()
        fn()
        print("RESULT %s run%d %.3f" % (name, n + 1, time.perf_counter() - t), flush=True)
