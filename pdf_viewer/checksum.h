#pragma once
#include <string>
#include <unordered_map>
#include <qcryptographichash.h>
#include <qstring.h>
#include <qfile.h>
#include <utility>
#include <optional>
#include <mutex>

std::string compute_checksum(const QString& file_name, QCryptographicHash::Algorithm hash_algorithm);

class CachedChecksummer {
private:
    std::recursive_mutex mutex;
    std::unordered_map<std::wstring, std::string> cached_checksums;
    std::unordered_map<std::string, std::vector<std::wstring>> cached_paths;

public:
    CachedChecksummer(const std::vector<std::pair<std::wstring, std::wstring>>* loaded_checksums);
    std::string get_checksum(std::wstring file_path);
    std::optional<std::string> get_checksum_fast(std::wstring file_path);
    std::optional<std::wstring> get_path(std::string checksum);
    int num_docs_with_checksum(std::string checksum);
    // make `file_path` use `checksum` (e.g. the checksum of the document a modified file was recognized as)
    void set_checksum(std::wstring file_path, std::string checksum);
};