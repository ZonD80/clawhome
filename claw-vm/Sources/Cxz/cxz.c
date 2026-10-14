#include "cxz.h"

#include "xz.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int write_all(int fd, const uint8_t *buf, size_t n, char *err, size_t err_len) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, buf + off, n - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            snprintf(err, err_len, "write unpacked image: %s", strerror(errno));
            return -1;
        }
        off += (size_t)w;
    }
    return 0;
}

static const char *xz_message(enum xz_ret ret) {
    switch (ret) {
    case XZ_MEM_ERROR: return "xz decoder ran out of memory";
    case XZ_MEMLIMIT_ERROR: return "xz dictionary is larger than 64 MiB";
    case XZ_FORMAT_ERROR: return "file is not an xz image";
    case XZ_OPTIONS_ERROR: return "xz options are not supported";
    case XZ_DATA_ERROR: return "xz data does not match its checksum";
    case XZ_BUF_ERROR: return "xz data ended early";
    default: return "xz decompress failed";
    }
}

int cxz_decompress_file(
    const char *src_path, int dst_fd, uint64_t *written, char *err, size_t err_len,
    cxz_progress_fn on_progress, void *ctx)
{
    FILE *in = fopen(src_path, "rb");
    if (!in) {
        snprintf(err, err_len, "open %s: %s", src_path, strerror(errno));
        return -1;
    }
    xz_crc32_init();
    xz_crc64_init();
    struct xz_dec *dec = xz_dec_init(XZ_DYNALLOC, 64U << 20);
    if (!dec) {
        fclose(in);
        snprintf(err, err_len, "xz decoder could not start");
        return -1;
    }
    uint8_t *inbuf = malloc(1 << 20);
    uint8_t *outbuf = malloc(1 << 20);
    if (!inbuf || !outbuf) {
        free(inbuf);
        free(outbuf);
        xz_dec_end(dec);
        fclose(in);
        snprintf(err, err_len, "xz decoder ran out of memory");
        return -1;
    }
    struct xz_buf b = {inbuf, 0, 0, outbuf, 0, 1 << 20};
    uint64_t total = 0;
    uint64_t reported = 0;
    int failed = 0;
    while (!failed) {
        if (b.in_pos == b.in_size) {
            b.in_size = fread(inbuf, 1, 1 << 20, in);
            b.in_pos = 0;
            if (b.in_size == 0 && ferror(in)) {
                snprintf(err, err_len, "read %s: %s", src_path, strerror(errno));
                failed = 1;
                break;
            }
        }
        enum xz_ret ret = xz_dec_run(dec, &b);
        if (b.out_pos != 0) {
            if (write_all(dst_fd, outbuf, b.out_pos, err, err_len) != 0) {
                failed = 1;
                break;
            }
            total += b.out_pos;
            b.out_pos = 0;
            if (on_progress && total - reported >= (8u << 20)) {
                reported = total;
                on_progress(total, ctx);
            }
        }
        if (ret == XZ_OK) continue;
        if (ret == XZ_STREAM_END) {
            if (on_progress) on_progress(total, ctx);
            break;
        }
        snprintf(err, err_len, "%s", xz_message(ret));
        failed = 1;
    }
    xz_dec_end(dec);
    free(inbuf);
    free(outbuf);
    fclose(in);
    if (written) *written = total;
    return failed ? -1 : 0;
}
