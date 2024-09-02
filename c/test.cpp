#include <fstream>
#include <ios>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "rdepinfo.h"

int main(int argc, char *argv[]) {

  std::vector<std::string> args{argv, argv + argc};

  auto *repo = repo_init();

  {
    std::ifstream ifs("PACKAGES", std::ios::binary);
    if (!ifs) {
      std::cerr << "Could not open file.\n";
      return 1;
    }

    std::stringstream ss;
    ss << ifs.rdbuf();
    std::string buffer{ss.str()};

    // read repo file
    if (repo_read(repo, buffer.data(), buffer.size()) == 0)
      std::cerr << "Failed to read repo.\n";
  }

  // make index
  auto *index = repo_index_init(repo);

  for (int i = 1; i < args.size(); ++i) {
    auto package = args.at(i);

    std::cerr << "Checking package " << package << "\n";

    auto *buf_out =
        repo_index_unsatisfied(index, repo, package.c_str(), package.length());

    if (buf_out == nullptr) {
      std::cerr << "    Package not found: " << package << "\n";
      continue;
    }

    // unmet dependencies found
    if (buf_out->len > 0) {
      std::cerr << package << "\n";
      for (int i = 0; i < buf_out->len; ++i) {
        std::cerr << "  ";
        debug_print_name_and_version(&buf_out->ptr[i]);
        std::cerr << "\n";
      }
    }

    // free buffer returned by repo_index_unsatisfied
    repo_name_version_buffer_destroy(buf_out);
  }

  // free buffers
  repo_index_deinit(index);
  repo_deinit(repo);
  return 0;
}
