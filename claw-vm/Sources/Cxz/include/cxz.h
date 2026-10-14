#ifndef CXZ_H
#define CXZ_H

#include <stddef.h>
#include <stdint.h>

typedef void (*cxz_progress_fn)(uint64_t written, void *ctx);

/* Decompress one .xz file onto the current offset of dst_fd. */
int cxz_decompress_file(
    const char *src_path, int dst_fd, uint64_t *written, char *err, size_t err_len,
    cxz_progress_fn on_progress, void *ctx);

#endif
