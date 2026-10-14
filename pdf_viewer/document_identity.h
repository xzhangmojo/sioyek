#pragma once

#include <string>
#include <optional>
#include <vector>
#include <functional>
#include <mutex>
#include <atomic>
#include <unordered_set>

#include "mupdf/fitz.h"

class DatabaseManager;
class CachedChecksummer;

// Gives every document a permanent id and recognizes its file after it was moved, renamed or modified.
// A document's annotations stay stored with its first checksum (its key), later checksums of the same
// document are aliases of it.
struct DocumentIdentity {
    std::string uuid;
    std::string key;
    int page_count = -1;
    std::string pdf_id;
    std::wstring title;
    std::string text_fingerprint;
    std::wstring sample_text;
    std::wstring file_name;
};

class DocumentIdentifier {
public:
    DocumentIdentifier(DatabaseManager* db_manager, CachedChecksummer* checksummer);
    ~DocumentIdentifier();

    // which document is the file at `path` (opened as `doc`)? registers a new document if it is unknown and
    // returns the key which the document's annotations are stored with
    std::string identify_file(const std::wstring& path, fz_context* ctx, fz_document* doc);

    // where is the file of `identity`? `ask_user` lets the user pick the file when everything else fails and
    // `confirm_mismatch` asks whether to use a picked file which doesn't look like the document
    std::optional<std::wstring> find_file(const DocumentIdentity& identity, fz_context* ctx,
        std::function<std::optional<std::wstring>()> ask_user,
        std::function<bool(const std::wstring&)> confirm_mismatch);

    std::optional<DocumentIdentity> get_by_uuid(const std::string& uuid);
    // `checksum` is the key or any other checksum the document had
    std::optional<DocumentIdentity> get_by_checksum(const std::string& checksum);
    // the document of a highlight or bookmark
    std::optional<DocumentIdentity> get_by_annotation_uuid(const std::string& annotation_uuid);
    // also creates identities for documents which were opened before identities existed
    std::optional<DocumentIdentity> get_or_create_for_key(const std::string& key);

    // documents with annotations (or anything else which would be lost if their file isn't recognized after it is
    // modified) get a text fingerprint, which is computed lazily in the background once per document
    bool is_protected(const std::string& key);
    void protect_document(const std::wstring& path, const std::string& key, fz_context* base_ctx);

private:
    struct FileState {
        long long size = -1;
        long long mtime = -1;
        std::string key;
    };

    DatabaseManager* db_manager;
    CachedChecksummer* checksummer;
    std::recursive_mutex mutex;
    std::unordered_set<std::string> protected_keys;
    std::atomic<bool> stopping = false;
    std::atomic<int> running_jobs = 0;

    void create_tables();
    void save_identity(const DocumentIdentity& identity);
    void add_alias(const std::string& checksum, const std::string& uuid);
    std::optional<DocumentIdentity> get_by_fingerprint(const std::string& fingerprint, int page_count);
    std::optional<FileState> saved_file_state(const std::wstring& path);
    void save_file_state(const std::wstring& path, const FileState& state);
    std::vector<std::wstring> known_paths(const std::string& key);
    // whether a document with a fingerprint and `page_count` pages has no unchanged file at a known path
    bool has_missing_document(int page_count);

    // whether the file at `path` is the document, `out_md5` is set if the checksum was computed
    bool is_file_of(const std::wstring& path, const DocumentIdentity& identity, fz_context* ctx, std::string* out_md5);
    // remembers that the document is at `path` so the next lookup finds it right away
    void remember_file(const std::wstring& path, const DocumentIdentity& identity, const std::string& md5);
};

DocumentIdentifier* get_document_identifier();
void set_document_identifier(DocumentIdentifier* identifier);
