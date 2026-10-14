#include "document_identity.h"

#include <algorithm>
#include <cwctype>
#include <qdebug.h>
#include <thread>
#include <chrono>
#include <qdir.h>
#include <qdiriterator.h>
#include <qfileinfo.h>
#include <qprocess.h>
#include <quuid.h>
#include <qcryptographichash.h>
#include <qstringlist.h>

#include <mupdf/pdf.h>

#include "database.h"
#include "checksum.h"
#include "utils.h"

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <sys/xattr.h>
#endif

extern std::wstring PAPERS_FOLDER_PATH;
extern std::wstring LIBRARY_FOLDERS;

namespace {

DocumentIdentifier* global_document_identifier = nullptr;

// number of pages whose text is used for the text fingerprint
const int FINGERPRINT_PAGES = 5;

class Statement {
    sqlite3_stmt* stmt = nullptr;
public:
    Statement(sqlite3* db, const char* sql) {
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
            qDebug() << "DocumentIdentifier: could not prepare" << sql << sqlite3_errmsg(db);
            stmt = nullptr;
        }
    }
    ~Statement() { sqlite3_finalize(stmt); }

    Statement& bind(int index, const std::string& value) {
        if (stmt) sqlite3_bind_text(stmt, index, value.c_str(), -1, SQLITE_TRANSIENT);
        return *this;
    }
    Statement& bind(int index, const std::wstring& value) { return bind(index, utf8_encode(value)); }
    Statement& bind_int(int index, long long value) {
        if (stmt) sqlite3_bind_int64(stmt, index, value);
        return *this;
    }
    bool next() { return stmt && (sqlite3_step(stmt) == SQLITE_ROW); }
    void run() { if (stmt) sqlite3_step(stmt); }
    std::string text(int column) {
        const unsigned char* value = sqlite3_column_text(stmt, column);
        return value ? std::string((const char*)value) : std::string();
    }
    long long integer(int column) { return sqlite3_column_int64(stmt, column); }
};

std::string new_document_uuid() {
    return QUuid::createUuid().toString(QUuid::WithoutBraces).toStdString();
}

std::string file_md5(const std::wstring& path) {
    return compute_checksum(QString::fromStdWString(path), QCryptographicHash::Md5);
}

void current_file_state(const std::wstring& path, long long* size, long long* mtime) {
    QFileInfo info(QString::fromStdWString(path));
    *size = info.size();
    *mtime = info.lastModified().toMSecsSinceEpoch();
}

// the document id is stored as an extended attribute of the file (like finder tags), which survives moves, renames
// and most edits and is indexed by spotlight because of the com.apple.metadata: prefix
const char* DOCUMENT_ID_ATTRIBUTE = "com.apple.metadata:info_sioyek_document_id";

std::optional<std::string> read_document_id_tag(const std::wstring& path) {
#ifdef __APPLE__
    std::string utf8_path = utf8_encode(path);
    ssize_t size = getxattr(utf8_path.c_str(), DOCUMENT_ID_ATTRIBUTE, nullptr, 0, 0, 0);
    if (size <= 0 || size > 4096) return {};

    std::vector<UInt8> buffer(size);
    if (getxattr(utf8_path.c_str(), DOCUMENT_ID_ATTRIBUTE, buffer.data(), size, 0, 0) != size) return {};

    // spotlight only indexes values which are property lists
    CFDataRef data = CFDataCreate(nullptr, buffer.data(), size);
    CFPropertyListRef value = CFPropertyListCreateWithData(nullptr, data, kCFPropertyListImmutable, nullptr, nullptr);
    CFRelease(data);
    std::optional<std::string> result;
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        char uuid[128];
        if (CFStringGetCString((CFStringRef)value, uuid, sizeof(uuid), kCFStringEncodingUTF8)) {
            result = uuid;
        }
    }
    if (value) CFRelease(value);
    return result;
#else
    return {};
#endif
}

void write_document_id_tag(const std::wstring& path, const std::string& uuid) {
#ifdef __APPLE__
    CFStringRef value = CFStringCreateWithCString(nullptr, uuid.c_str(), kCFStringEncodingUTF8);
    CFDataRef data = CFPropertyListCreateData(nullptr, value, kCFPropertyListBinaryFormat_v1_0, 0, nullptr);
    if (data) {
        // fails silently for read-only files, the other ways of recognizing the file still work
        setxattr(utf8_encode(path).c_str(), DOCUMENT_ID_ATTRIBUTE, CFDataGetBytePtr(data), CFDataGetLength(data), 0, 0);
        CFRelease(data);
    }
    CFRelease(value);
#endif
}

// the text of the page's own content, without annotations (which other apps may add when saving the file)
std::wstring page_content_text(fz_context* ctx, fz_document* doc, int page_number) {
    std::wstring result;
    fz_page* page = nullptr;
    fz_stext_page* stext = nullptr;
    fz_device* device = nullptr;
    fz_var(page);
    fz_var(stext);
    fz_var(device);

    std::function<void(fz_stext_block*)> add_blocks = [&](fz_stext_block* block) {
        for (; block; block = block->next) {
            if (block->type == FZ_STEXT_BLOCK_TEXT) {
                for (fz_stext_line* line = block->u.t.first_line; line; line = line->next) {
                    for (fz_stext_char* ch = line->first_char; ch; ch = ch->next) {
                        result.push_back((wchar_t)ch->c);
                    }
                    result.push_back(L'\n');
                }
            }
            else if (block->type == FZ_STEXT_BLOCK_STRUCT && block->u.s.down) {
                add_blocks(block->u.s.down->first_block);
            }
        }
    };

    fz_try(ctx) {
        page = fz_load_page(ctx, doc, page_number);
        stext = fz_new_stext_page(ctx, fz_bound_page(ctx, page));
        device = fz_new_stext_device(ctx, stext, nullptr);
        fz_run_page_contents(ctx, page, device, fz_identity, nullptr);
        fz_close_device(ctx, device);
        add_blocks(stext->first_block);
    }
    fz_always(ctx) {
        fz_drop_device(ctx, device);
        fz_drop_stext_page(ctx, stext);
        fz_drop_page(ctx, page);
    }
    fz_catch(ctx) {
    }
    return result;
}

int count_pages(fz_context* ctx, fz_document* doc) {
    int page_count = -1;
    fz_var(page_count);
    fz_try(ctx) {
        page_count = fz_count_pages(ctx, doc);
    }
    fz_catch(ctx) {
    }
    return page_count;
}

// the parts of DocumentIdentity which are cheap to compute
void compute_basic_identity(fz_context* ctx, fz_document* doc, DocumentIdentity& identity) {
    identity.page_count = -1;
    fz_try(ctx) {
        identity.page_count = fz_count_pages(ctx, doc);
    }
    fz_catch(ctx) {
    }

    char buffer[1024] = { 0 };
    if (fz_lookup_metadata(ctx, doc, FZ_META_INFO_TITLE, buffer, sizeof(buffer)) > 0) {
        identity.title = utf8_decode(buffer);
    }

    // the first part of the pdf's file identifier is meant to stay the same when the file is changed
    if (pdf_document* pdf = pdf_specifics(ctx, doc)) {
        fz_try(ctx) {
            pdf_obj* id = pdf_dict_get(ctx, pdf_trailer(ctx, pdf), PDF_NAME(ID));
            pdf_obj* first = pdf_array_get(ctx, id, 0);
            if (pdf_is_string(ctx, first)) {
                QByteArray bytes(pdf_to_str_buf(ctx, first), (int)pdf_to_str_len(ctx, first));
                identity.pdf_id = bytes.toHex().toStdString();
            }
        }
        fz_catch(ctx) {
        }
    }

}

// the text fingerprint and sample text, which need the text of the first pages
void compute_text_identity(fz_context* ctx, fz_document* doc, DocumentIdentity& identity) {
    if (identity.page_count < 0) identity.page_count = count_pages(ctx, doc);

    std::wstring normalized;
    std::vector<QStringList> lines;
    int num_pages = std::min(identity.page_count, FINGERPRINT_PAGES);
    for (int i = 0; i < num_pages; i++) {
        std::wstring text = page_content_text(ctx, doc, i);
        for (wchar_t c : text) {
            if (std::iswalnum(c)) normalized.push_back(std::towlower(c));
        }
        for (const QString& line : QString::fromStdWString(text).split('\n', Qt::SkipEmptyParts)) {
            QStringList words;
            for (const QString& word : line.split(' ', Qt::SkipEmptyParts)) {
                bool is_plain_word = word.size() >= 3;
                for (QChar c : word) {
                    if (!c.isLetter()) {
                        is_plain_word = false;
                        break;
                    }
                }
                if (!is_plain_word) break;
                words.push_back(word);
            }
            lines.push_back(words);
        }
    }

    identity.text_fingerprint.clear();
    if (normalized.size() > 0) {
        QByteArray data = QString::fromStdWString(normalized + L":" + std::to_wstring(identity.page_count)).toUtf8();
        identity.text_fingerprint = QCryptographicHash::hash(data, QCryptographicHash::Md5).toHex().toStdString();
    }

    // a few consecutive words from one line of text (which spotlight can search for), the line with the most of them
    identity.sample_text.clear();
    const QStringList* best = nullptr;
    for (const QStringList& words : lines) {
        if (words.size() >= 5 && (best == nullptr || words.size() > best->size())) best = &words;
    }
    if (best) {
        identity.sample_text = best->mid(0, 8).join(' ').toStdWString();
    }
}

void compute_content_identity(fz_context* ctx, fz_document* doc, DocumentIdentity& identity) {
    compute_basic_identity(ctx, doc, identity);
    compute_text_identity(ctx, doc, identity);
}

#ifdef Q_OS_MACOS
std::vector<std::wstring> spotlight_search(const QString& query) {
    QProcess process;
    process.start("/usr/bin/mdfind", { query });
    std::vector<std::wstring> result;
    if (!process.waitForFinished(5000)) {
        process.kill();
        return result;
    }
    for (const QString& line : QString::fromUtf8(process.readAllStandardOutput()).split('\n', Qt::SkipEmptyParts)) {
        result.push_back(line.toStdWString());
    }
    return result;
}

QString spotlight_string(const std::wstring& value) {
    QString result = QString::fromStdWString(value);
    result.replace("\\", "\\\\").replace("\"", "\\\"").replace("*", "\\*");
    return result;
}
#endif

} // namespace

DocumentIdentifier* get_document_identifier() {
    return global_document_identifier;
}

void set_document_identifier(DocumentIdentifier* identifier) {
    global_document_identifier = identifier;
}

DocumentIdentifier::DocumentIdentifier(DatabaseManager* db_manager_, CachedChecksummer* checksummer_)
    : db_manager(db_manager_), checksummer(checksummer_) {
    create_tables();
}

void DocumentIdentifier::create_tables() {
    std::lock_guard<std::recursive_mutex> lock(db_manager->get_mutex());
    // documents and their checksums are shared like the annotations, file locations are local
    sqlite3_exec(db_manager->get_global_db(), "CREATE TABLE IF NOT EXISTS documents ("
        "uuid TEXT PRIMARY KEY, key TEXT, page_count INTEGER, pdf_id TEXT, title TEXT,"
        "text_fingerprint TEXT, sample_text TEXT, file_name TEXT);", nullptr, nullptr, nullptr);
    sqlite3_exec(db_manager->get_global_db(), "CREATE TABLE IF NOT EXISTS document_aliases ("
        "checksum TEXT PRIMARY KEY, uuid TEXT);", nullptr, nullptr, nullptr);
    sqlite3_exec(db_manager->get_global_db(), "CREATE INDEX IF NOT EXISTS documents_fingerprint "
        "ON documents (text_fingerprint);", nullptr, nullptr, nullptr);
    sqlite3_exec(db_manager->get_local_db(), "CREATE TABLE IF NOT EXISTS file_states ("
        "path TEXT PRIMARY KEY, size INTEGER, mtime INTEGER, key TEXT);", nullptr, nullptr, nullptr);
}

std::optional<DocumentIdentity> DocumentIdentifier::get_by_uuid(const std::string& uuid) {
    std::lock_guard<std::recursive_mutex> lock(db_manager->get_mutex());
    Statement query(db_manager->get_global_db(), "SELECT uuid, key, page_count, pdf_id, title, text_fingerprint, "
        "sample_text, file_name FROM documents WHERE uuid=?;");
    query.bind(1, uuid);
    if (!query.next()) return {};

    DocumentIdentity identity;
    identity.uuid = query.text(0);
    identity.key = query.text(1);
    identity.page_count = (int)query.integer(2);
    identity.pdf_id = query.text(3);
    identity.title = utf8_decode(query.text(4));
    identity.text_fingerprint = query.text(5);
    identity.sample_text = utf8_decode(query.text(6));
    identity.file_name = utf8_decode(query.text(7));
    return identity;
}

std::optional<DocumentIdentity> DocumentIdentifier::get_by_checksum(const std::string& checksum) {
    std::string uuid;
    {
        std::lock_guard<std::recursive_mutex> lock(db_manager->get_mutex());
        Statement query(db_manager->get_global_db(), "SELECT uuid FROM document_aliases WHERE checksum=?;");
        query.bind(1, checksum);
        if (!query.next()) return {};
        uuid = query.text(0);
    }
    return get_by_uuid(uuid);
}

std::optional<DocumentIdentity> DocumentIdentifier::get_by_annotation_uuid(const std::string& annotation_uuid) {
    std::string key;
    {
        std::lock_guard<std::recursive_mutex> lock(db_manager->get_mutex());
        Statement query(db_manager->get_global_db(), "SELECT document_path FROM highlights WHERE uuid=? "
            "UNION SELECT document_path FROM bookmarks WHERE uuid=?;");
        query.bind(1, annotation_uuid).bind(2, annotation_uuid);
        if (!query.next()) return {};
        key = query.text(0);
    }
    return get_or_create_for_key(key);
}

std::optional<DocumentIdentity> DocumentIdentifier::get_or_create_for_key(const std::string& key) {
    if (key.empty()) return {};
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (auto identity = get_by_checksum(key)) {
        return identity;
    }

    // only for documents sioyek knows about (opened before identities existed)
    std::vector<std::wstring> paths;
    db_manager->get_path_from_hash(key, paths);
    bool has_annotations = false;
    {
        std::lock_guard<std::recursive_mutex> db_lock(db_manager->get_mutex());
        Statement query(db_manager->get_global_db(), "SELECT 1 FROM highlights WHERE document_path=? "
            "UNION SELECT 1 FROM bookmarks WHERE document_path=? UNION SELECT 1 FROM opened_books WHERE path=?;");
        query.bind(1, key).bind(2, key).bind(3, key);
        has_annotations = query.next();
    }
    if (paths.empty() && !has_annotations) return {};

    DocumentIdentity identity;
    identity.uuid = new_document_uuid();
    identity.key = key;
    if (!paths.empty()) {
        identity.file_name = QFileInfo(QString::fromStdWString(paths.back())).fileName().toStdWString();
    }
    save_identity(identity);
    add_alias(key, identity.uuid);
    return identity;
}

std::optional<DocumentIdentity> DocumentIdentifier::get_by_fingerprint(const std::string& fingerprint, int page_count) {
    std::string uuid;
    {
        std::lock_guard<std::recursive_mutex> lock(db_manager->get_mutex());
        Statement query(db_manager->get_global_db(), "SELECT uuid FROM documents WHERE text_fingerprint=? AND page_count=?;");
        query.bind(1, fingerprint).bind_int(2, page_count);
        if (!query.next()) return {};
        uuid = query.text(0);
    }
    return get_by_uuid(uuid);
}

void DocumentIdentifier::save_identity(const DocumentIdentity& identity) {
    std::lock_guard<std::recursive_mutex> lock(db_manager->get_mutex());
    Statement query(db_manager->get_global_db(), "INSERT OR REPLACE INTO documents (uuid, key, page_count, pdf_id, "
        "title, text_fingerprint, sample_text, file_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?);");
    query.bind(1, identity.uuid).bind(2, identity.key).bind_int(3, identity.page_count).bind(4, identity.pdf_id)
        .bind(5, identity.title).bind(6, identity.text_fingerprint).bind(7, identity.sample_text).bind(8, identity.file_name);
    query.run();
}

void DocumentIdentifier::add_alias(const std::string& checksum, const std::string& uuid) {
    if (checksum.empty()) return;
    std::lock_guard<std::recursive_mutex> lock(db_manager->get_mutex());
    Statement query(db_manager->get_global_db(), "INSERT OR REPLACE INTO document_aliases (checksum, uuid) VALUES (?, ?);");
    query.bind(1, checksum).bind(2, uuid);
    query.run();
}

std::optional<DocumentIdentifier::FileState> DocumentIdentifier::saved_file_state(const std::wstring& path) {
    std::lock_guard<std::recursive_mutex> lock(db_manager->get_mutex());
    Statement query(db_manager->get_local_db(), "SELECT size, mtime, key FROM file_states WHERE path=?;");
    query.bind(1, path);
    if (!query.next()) return {};
    return FileState{ query.integer(0), query.integer(1), query.text(2) };
}

void DocumentIdentifier::save_file_state(const std::wstring& path, const FileState& state) {
    std::lock_guard<std::recursive_mutex> lock(db_manager->get_mutex());
    Statement query(db_manager->get_local_db(), "INSERT OR REPLACE INTO file_states (path, size, mtime, key) VALUES (?, ?, ?, ?);");
    query.bind(1, path).bind_int(2, state.size).bind_int(3, state.mtime).bind(4, state.key);
    query.run();
}

std::vector<std::wstring> DocumentIdentifier::known_paths(const std::string& key) {
    std::vector<std::wstring> paths;
    db_manager->get_path_from_hash(key, paths);
    std::lock_guard<std::recursive_mutex> lock(db_manager->get_mutex());
    Statement query(db_manager->get_local_db(), "SELECT path FROM file_states WHERE key=?;");
    query.bind(1, key);
    while (query.next()) {
        std::wstring path = utf8_decode(query.text(0));
        if (std::find(paths.begin(), paths.end(), path) == paths.end()) paths.push_back(path);
    }
    return paths;
}

std::string DocumentIdentifier::identify_file(const std::wstring& path, fz_context* ctx, fz_document* doc) {
    std::lock_guard<std::recursive_mutex> lock(mutex);

    FileState state;
    current_file_state(path, &state.size, &state.mtime);
    int page_count = count_pages(ctx, doc);

    std::optional<DocumentIdentity> identity;
    std::string md5;
    bool is_new = false;

    // 1. the document id tag on the file
    if (std::optional<std::string> tag = read_document_id_tag(path)) {
        if (std::optional<DocumentIdentity> tagged = get_by_uuid(tag.value())) {
            // a copy of a tagged file which was changed into a different document keeps the tag
            if (tagged->page_count < 0 || tagged->page_count == page_count) {
                identity = tagged;
            }
        }
    }

    // 2. a known path whose file didn't change
    if (!identity) {
        if (std::optional<FileState> saved = saved_file_state(path)) {
            if (saved->size == state.size && saved->mtime == state.mtime) {
                identity = get_or_create_for_key(saved->key);
            }
        }
        else if (std::optional<std::string> previous_key = checksummer->get_checksum_fast(path)) {
            // the file was opened before identities existed
            identity = get_or_create_for_key(previous_key.value());
        }
    }

    // 3. the checksum
    if (!identity) {
        md5 = file_md5(path);
        identity = get_by_checksum(md5);
    }

    // 4. the text, which stays the same when other apps save annotations into the file. reading it is only worth it
    // when a document which could be this file has gone missing
    if (!identity && has_missing_document(page_count)) {
        DocumentIdentity content;
        content.page_count = page_count;
        compute_text_identity(ctx, doc, content);
        if (!content.text_fingerprint.empty()) {
            identity = get_by_fingerprint(content.text_fingerprint, page_count);
        }
    }

    // a new document
    if (!identity) {
        identity = DocumentIdentity();
        identity->uuid = new_document_uuid();
        identity->key = md5.empty() ? file_md5(path) : md5;
        is_new = true;
    }

    if (is_new || identity->page_count < 0) {
        compute_basic_identity(ctx, doc, identity.value());
        identity->file_name = QFileInfo(QString::fromStdWString(path)).fileName().toStdWString();
        save_identity(identity.value());
        add_alias(identity->key, identity->uuid);
    }
    remember_file(path, identity.value(), md5);
    return identity->key;
}

bool DocumentIdentifier::has_missing_document(int page_count) {
    // only protected documents have a fingerprint
    std::vector<std::string> keys;
    {
        std::lock_guard<std::recursive_mutex> lock(db_manager->get_mutex());
        Statement query(db_manager->get_global_db(), "SELECT key FROM documents WHERE page_count=? AND text_fingerprint != '';");
        query.bind_int(1, page_count);
        while (query.next()) keys.push_back(query.text(0));
    }

    for (const std::string& key : keys) {
        bool is_present = false;
        for (const std::wstring& path : known_paths(key)) {
            std::optional<FileState> saved = saved_file_state(path);
            FileState current;
            current_file_state(path, &current.size, &current.mtime);
            if (saved && saved->key == key && saved->size == current.size && saved->mtime == current.mtime &&
                QFileInfo(QString::fromStdWString(path)).isFile()) {
                is_present = true;
                break;
            }
        }
        if (!is_present) return true;
    }
    return false;
}

void DocumentIdentifier::remember_file(const std::wstring& path, const DocumentIdentity& identity, const std::string& md5) {
    // nothing is written when nothing changed, which is the case for almost every file that is opened
    std::wstring file_name = QFileInfo(QString::fromStdWString(path)).fileName().toStdWString();
    if (identity.file_name != file_name) {
        DocumentIdentity updated = identity;
        updated.file_name = file_name;
        save_identity(updated);
    }
    add_alias(md5, identity.uuid);

    if (read_document_id_tag(path) != identity.uuid) {
        write_document_id_tag(path, identity.uuid);
    }

    FileState state;
    current_file_state(path, &state.size, &state.mtime);
    state.key = identity.key;
    std::optional<FileState> saved = saved_file_state(path);
    if (!saved || saved->size != state.size || saved->mtime != state.mtime || saved->key != state.key) {
        save_file_state(path, state);
    }

    if (checksummer->get_checksum_fast(path) != identity.key) {
        db_manager->insert_document_hash(path, identity.key);
        checksummer->set_checksum(path, identity.key);
    }
}

bool DocumentIdentifier::is_protected(const std::string& key) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    return protected_keys.find(key) != protected_keys.end();
}

void DocumentIdentifier::protect_document(const std::wstring& path, const std::string& key, fz_context* base_ctx) {
    {
        std::lock_guard<std::recursive_mutex> lock(mutex);
        if (!protected_keys.insert(key).second) return;
    }
    std::optional<DocumentIdentity> identity = get_by_checksum(key);
    if (!identity || !identity->text_fingerprint.empty()) return;

    fz_context* ctx = fz_clone_context(base_ctx);
    running_jobs++;
    std::thread([this, path, key, ctx]() {
        // lazily, so it doesn't compete with opening and rendering the document
        for (int i = 0; i < 30 && !stopping; i++) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        DocumentIdentity content;
        if (!stopping) {
            fz_document* doc = nullptr;
            fz_var(doc);
            fz_try(ctx) {
                doc = open_document_with_file_name(ctx, path);
                compute_text_identity(ctx, doc, content);
            }
            fz_always(ctx) {
                fz_drop_document(ctx, doc);
            }
            fz_catch(ctx) {
            }
        }
        fz_drop_context(ctx);

        if (!stopping && !content.text_fingerprint.empty()) {
            std::lock_guard<std::recursive_mutex> lock(mutex);
            if (std::optional<DocumentIdentity> identity = get_by_checksum(key)) {
                identity->text_fingerprint = content.text_fingerprint;
                identity->sample_text = content.sample_text;
                save_identity(identity.value());
            }
        }
        running_jobs--;
        }).detach();
}

DocumentIdentifier::~DocumentIdentifier() {
    stopping = true;
    while (running_jobs > 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
}

bool DocumentIdentifier::is_file_of(const std::wstring& path, const DocumentIdentity& identity, fz_context* ctx, std::string* out_md5) {
    if (!QFileInfo(QString::fromStdWString(path)).isFile()) return false;

    if (std::optional<std::string> tag = read_document_id_tag(path)) {
        return tag.value() == identity.uuid;
    }

    FileState state;
    current_file_state(path, &state.size, &state.mtime);
    if (std::optional<FileState> saved = saved_file_state(path)) {
        if (saved->size == state.size && saved->mtime == state.mtime) {
            return saved->key == identity.key;
        }
    }

    std::string md5 = file_md5(path);
    if (out_md5) *out_md5 = md5;
    if (md5 == identity.key) return true;
    if (std::optional<DocumentIdentity> by_checksum = get_by_checksum(md5)) {
        return by_checksum->uuid == identity.uuid;
    }

    if (identity.text_fingerprint.empty() || ctx == nullptr) return false;

    bool matches = false;
    fz_document* doc = nullptr;
    fz_var(doc);
    fz_var(matches);
    fz_try(ctx) {
        doc = open_document_with_file_name(ctx, path);
        // opening the document is cheap compared to extracting its text, so the page count is checked first
        if (doc && fz_count_pages(ctx, doc) == identity.page_count) {
            DocumentIdentity content;
            compute_content_identity(ctx, doc, content);
            matches = content.text_fingerprint == identity.text_fingerprint;
        }
    }
    fz_always(ctx) {
        fz_drop_document(ctx, doc);
    }
    fz_catch(ctx) {
    }
    return matches;
}

std::optional<std::wstring> DocumentIdentifier::find_file(const DocumentIdentity& identity, fz_context* ctx,
    std::function<std::optional<std::wstring>()> ask_user,
    std::function<bool(const std::wstring&)> confirm_mismatch) {

    std::lock_guard<std::recursive_mutex> lock(mutex);
    std::vector<std::wstring> checked;

    auto try_candidates = [&](const std::vector<std::wstring>& candidates) -> std::optional<std::wstring> {
        for (const std::wstring& candidate : candidates) {
            if (std::find(checked.begin(), checked.end(), candidate) != checked.end()) continue;
            checked.push_back(candidate);

            std::string md5;
            if (is_file_of(candidate, identity, ctx, &md5)) {
                remember_file(candidate, identity, md5);
                return candidate;
            }
        }
        return {};
    };

    // 1. where the document was before
    if (auto found = try_candidates(known_paths(identity.key))) return found;

#ifdef Q_OS_MACOS
    // 2. spotlight search for the document id tag
    QString uuid_query = QString("info_sioyek_document_id == \"%1\"").arg(QString::fromStdString(identity.uuid));
    if (auto found = try_candidates(spotlight_search(uuid_query))) return found;

    // 3. the names the file had
    std::vector<std::wstring> names;
    if (!identity.file_name.empty()) names.push_back(identity.file_name);
    for (const std::wstring& path : known_paths(identity.key)) {
        std::wstring name = QFileInfo(QString::fromStdWString(path)).fileName().toStdWString();
        if (std::find(names.begin(), names.end(), name) == names.end()) names.push_back(name);
    }
    for (const std::wstring& name : names) {
        if (auto found = try_candidates(spotlight_search(QString("kMDItemFSName == \"%1\"c").arg(spotlight_string(name))))) {
            return found;
        }
    }

    // 4. the title and number of pages
    if (!identity.title.empty() && identity.page_count > 0) {
        QString query = QString("kMDItemTitle == \"%1\"c && kMDItemNumberOfPages == %2")
            .arg(spotlight_string(identity.title)).arg(identity.page_count);
        if (auto found = try_candidates(spotlight_search(query))) return found;
    }

    // 5. a few words of its text
    if (!identity.sample_text.empty()) {
        QString query = QString("kMDItemContentType == \"com.adobe.pdf\" && kMDItemTextContent == \"%1\"cd")
            .arg(spotlight_string(identity.sample_text));
        if (auto found = try_candidates(spotlight_search(query))) return found;
    }
#endif

    // 6. the library folders
    QStringList folders = QString::fromStdWString(LIBRARY_FOLDERS).split(';', Qt::SkipEmptyParts);
    if (!PAPERS_FOLDER_PATH.empty()) folders.push_back(QString::fromStdWString(PAPERS_FOLDER_PATH));
    for (QString folder : folders) {
        folder = folder.trimmed();
        if (folder.startsWith("~/")) folder = QDir::homePath() + folder.mid(1);
        std::vector<std::wstring> candidates;
        QDirIterator it(folder, { "*.pdf", "*.PDF" }, QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            candidates.push_back(it.next().toStdWString());
        }
        if (auto found = try_candidates(candidates)) return found;
    }

    // 7. ask the user
    if (ask_user) {
        if (std::optional<std::wstring> picked = ask_user()) {
            std::string md5;
            if (is_file_of(picked.value(), identity, ctx, &md5) || (confirm_mismatch && confirm_mismatch(picked.value()))) {
                if (md5.empty()) md5 = file_md5(picked.value());
                remember_file(picked.value(), identity, md5);
                return picked;
            }
        }
    }
    return {};
}
