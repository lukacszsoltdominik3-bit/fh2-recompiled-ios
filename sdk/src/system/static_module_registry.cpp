#include <rex/system/static_module_registry.h>

#include <string>
#include <unordered_map>

namespace rex::system {

namespace {
std::unordered_map<std::string, StaticModuleEntry>& Table() {
  static std::unordered_map<std::string, StaticModuleEntry> g_table;
  return g_table;
}
}  // namespace

void RegisterStaticModule(const char* shared_lib_name, StaticModuleEntry entry) {
  Table().emplace(std::string(shared_lib_name), entry);
}

const StaticModuleEntry* LookupStaticModule(const char* shared_lib_name) {
  auto it = Table().find(std::string(shared_lib_name));
  return it == Table().end() ? nullptr : &it->second;
}

}  // namespace rex::system
