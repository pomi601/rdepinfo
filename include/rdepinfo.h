#ifndef RDEPINFO_H
#define RDEPINFO_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

extern void *repo_init();
extern void repo_deinit(void *repo);
extern size_t repo_read(void *repo, char *buf, size_t sz);

#ifdef __cplusplus
}
#endif

#endif
