#include <fstream>
#include <ios>
#include <iostream>
#include <vector>

#include "rdepinfo.h"

int main(void) {
  void *repo = repo_init();
  std::cerr << "repo: " << std::hex << repo << "\n";

  {
    std::ifstream file("../r/PACKAGES-all.gz", std::ios::binary);
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
  repo_deinit(repo);
  return 0;
}
