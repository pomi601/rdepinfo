#ifndef RDEPINFO_H
#define RDEPINFO_H

#include <cstddef>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

enum Constraint : uint8_t { lt, lte, eq, gte, gt };

struct Version {
  uint32_t major, minor, patch, rev;
};

struct VersionConstraint {
  Constraint constraint;
  Version version;
};

struct CNameAndVersion {
  char const *name_ptr;
  std::size_t name_len;
  VersionConstraint version;
};

struct NameAndVersionBuffer {
  CNameAndVersion *ptr;
  std::size_t len;
};

extern void *repo_init();
extern void repo_deinit(void *repo);
extern size_t repo_read(void *repo, char *buf, size_t sz);

extern void *repo_index_init(void *repo);
extern void repo_index_deinit(void *index);
extern NameAndVersionBuffer *
repo_index_unsatisfied(void *index, NameAndVersionBuffer const *buf);

extern NameAndVersionBuffer *repo_name_version_buffer_create(std::size_t n);
extern void repo_name_version_buffer_destroy(NameAndVersionBuffer *buf);

#ifdef __cplusplus
}
#endif

#endif
