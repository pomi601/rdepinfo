#include <fstream>
#include <ios>
#include <iostream>
#include <string>
#include <vector>

#include "rdepinfo.h"

void print(CNameAndVersion nv) {
  std::cerr << "(name: " << std::string{nv.name_ptr, nv.name_len}
            << " constraint: " << static_cast<int>(nv.version.constraint)
            << " version: " << nv.version.version.major << "."
            << nv.version.version.minor << "." << nv.version.version.patch
            << "." << nv.version.version.rev << ")" << "\n";
}

int main(void) {
  auto *repo = repo_init();
  std::cerr << "repo: " << std::hex << repo << "\n";

  {
    std::ifstream file("PACKAGES.gz", std::ios::binary);
    if (!file) {
      std::cerr << "Could not open file.\n";
      return 1;
    }

    std::streamsize sz = file.tellg();
    std::vector<char> buffer(sz);
    if (file.read(buffer.data(), sz)) {
      repo_read(repo, buffer.data(), sz);
      std::cerr << "Successfully read file.\n";
    } else {
      std::cerr << "Error reading file.\n";
      return 1;
    }
  }

  auto *index = repo_index_init(repo);

  std::string package = "A3";

  auto *buf_in = repo_name_version_buffer_create(1);
  if (buf_in == nullptr) {
    std::cerr << "Could not create name_version_buffer.\n";
    return 1;
  }
  buf_in->ptr[0].name_ptr = package.c_str();
  buf_in->ptr[0].name_len = package.length();
  buf_in->ptr[0].version.constraint = gte;

  std::cerr << "buf_in 0: ";
  print(buf_in->ptr[0]);

  auto *buf_out = repo_index_unsatisfied(index, buf_in);
  if (buf_out == nullptr) {
    std::cerr << "repo_index_unsatisfied failed.\n";
    return 1;
  }

  std::cerr << "buf_out 0: ";
  print(buf_out->ptr[0]);

  std::cerr << "Got " << buf_out->len << " broken package(s).\n";
  for (int i = 0; i < buf_out->len; ++i) {
    std::string name{buf_out->ptr[i].name_ptr, buf_out->ptr[i].name_len};
    std::cerr << "  " << name << "\n";
  }

  repo_index_deinit(index);
  repo_deinit(repo);
  return 0;
}
