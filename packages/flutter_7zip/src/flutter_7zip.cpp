#include "flutter_7zip.h"
#include "7zip/C/7zCrc.h"
#include "7zip/C/7z.h"
#include "7zip/C/7zFile.h"
#include <iostream>
#include <fstream>
#include <algorithm>
#include <string>
#ifdef _WIN32
// Keeps windows.h from defining min/max macros, which break std::min/max.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

void *_AllocImp(ISzAllocPtr p, size_t size) {
  return malloc(size);
}

void _FreeImp(ISzAllocPtr p, void *ptr) {
  if (ptr != nullptr) {
    free(ptr);
  }
}

static ISzAlloc AllocImp = { _AllocImp, _FreeImp };

#ifdef _WIN32
// The Dart side passes UTF-8. The ANSI file APIs would read it in the
// system code page and fail on (or misname) any non-ASCII path.
static std::wstring Utf8ToWide(const char* utf8) {
  const int len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
  if (len <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(len), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide.data(), len);
  wide.resize(static_cast<size_t>(len - 1));
  return wide;
}
#endif

class Archive {
  CFileInStream archiveStream;
  CLookToRead2 lookStream;
  CSzArEx db;
  ISzAlloc allocImp = AllocImp;
  ISzAlloc allocTempImp = AllocImp;
  bool fileOpen = false;

  // The last decoded folder, kept between calls. SzArEx_Extract reuses it
  // when the next file lives in the same folder; freeing it after every file
  // made a solid archive decode its whole folder once per file.
  mutable UInt32 blockIndex = 0xFFFFFFFF;
  mutable Byte* outBuffer = nullptr;
  mutable size_t outBufferSize = 0;

public:
  ArchiveStatus status = kArchiveOK;

  explicit Archive(const char* path) {
    lookStream.buf = nullptr;
    SzArEx_Init(&db);
    File_Construct(&archiveStream.file);
#ifdef _WIN32
    const std::wstring widePath = Utf8ToWide(path);
    const WRes openRes = widePath.empty() ? 1 : InFile_OpenW(&archiveStream.file, widePath.c_str());
#else
    const WRes openRes = InFile_Open(&archiveStream.file, path);
#endif
    if (openRes) {
      status = kArchiveOpenError;
      return;
    }
    fileOpen = true;
    CrcGenerateTable();
    FileInStream_CreateVTable(&archiveStream);
    lookStream.realStream = &archiveStream.vt;
    lookStream.buf = new Byte[16 * 1024];
    lookStream.bufSize = 16 * 1024;
    LookToRead2_CreateVTable(&lookStream, False);
    LookToRead2_INIT(&lookStream);
    if (const auto res = SzArEx_Open(&db, &lookStream.vt, &allocImp, &allocTempImp); res != SZ_OK) {
      status = kArchiveOpenError;
    }
  }

  ~Archive() {
    _FreeImp(&allocImp, outBuffer);
    SzArEx_Free(&db, &allocImp);
    if (fileOpen) File_Close(&archiveStream.file);
    delete [] lookStream.buf;
  }

  /// Decodes [index] into the cached folder buffer. On success the file's
  /// bytes are outBuffer[offset, offset + size).
  SRes extract(const uint32_t index, size_t* offset, size_t* size) const {
    const SRes res = SzArEx_Extract(&db, const_cast<ILookInStreamPtr>(&lookStream.vt), index,
                                    &blockIndex, &outBuffer, &outBufferSize, offset, size,
                                    const_cast<ISzAllocPtr>(&allocImp),
                                    const_cast<ISzAllocPtr>(&allocTempImp));
    if (res != SZ_OK) {
      // A failed decode can leave the cache claiming a block it never
      // finished; the next file of that block would read the partial buffer.
      _FreeImp(&allocImp, outBuffer);
      outBuffer = nullptr;
      outBufferSize = 0;
      blockIndex = 0xFFFFFFFF;
    }
    return res;
  }

  uint32_t numFiles() const {
    return db.NumFiles;
  }

  ArchiveFile getFileByIndex(const uint32_t index) const {
    ArchiveFile archiveFile;

    archiveFile.is_dir = SzArEx_IsDir(&db, index) ? 1 : 0;

    const size_t offs = db.FileNameOffsets[index];
    const size_t len = db.FileNameOffsets[index + 1] - offs;
    auto fileName = new uint16_t[len+1];
    for (auto i = 0; i < len; i++) {
      fileName[i] = db.FileNames[offs*2 + i*2] + (db.FileNames[offs*2 + i*2 + 1] << 8);
    }
    fileName[len] = 0;
    archiveFile.name = fileName;

    archiveFile.size = SzArEx_GetFileSize(&db, index);

    // Defs are bit arrays (one bit per file), not byte arrays: indexing them
    // as bytes read past their end for any archive with more than a few files.
    archiveFile.crc32 = SzBitWithVals_Check(&db.CRCs, index) ? db.CRCs.Vals[index] : 0;

    if (SzBitWithVals_Check(&db.CTime, index)) {
      auto [Low, High] = db.CTime.Vals[index];
      archiveFile.cTime = Low + (static_cast<uint64_t>(High) << 32);
    } else {
      archiveFile.cTime = 0;
    }

    if (SzBitWithVals_Check(&db.MTime, index)) {
      auto [Low, High] = db.MTime.Vals[index];
      archiveFile.mTime = Low + (static_cast<uint64_t>(High) << 32);
    } else {
      archiveFile.mTime = 0;
    }

    return archiveFile;
  }

  unsigned char* readFile(const uint32_t index) const {
    // Not getFileByIndex: it allocates the name, which nothing here frees.
    if (index >= db.NumFiles || SzArEx_IsDir(&db, index)) {
      return nullptr;
    }
    const size_t fileSize = SzArEx_GetFileSize(&db, index);
    size_t offset = 0;
    size_t outSizeProcessed = 0;
    if (extract(index, &offset, &outSizeProcessed) != SZ_OK || outSizeProcessed != fileSize) {
      return nullptr;
    }
    auto* buffer = new unsigned char[fileSize > 0 ? fileSize : 1];
    std::copy(outBuffer + offset, outBuffer + offset + outSizeProcessed, buffer);
    return buffer;
  }

  ArchiveStatus extractFileToPath(const uint32_t index, const char* path) const {
    if (index >= db.NumFiles || SzArEx_IsDir(&db, index)) {
      return kArchiveReadError;
    }
    const size_t fileSize = SzArEx_GetFileSize(&db, index);
    size_t offset = 0;
    size_t outSizeProcessed = 0;
    if (extract(index, &offset, &outSizeProcessed) != SZ_OK || outSizeProcessed != fileSize) {
      return kArchiveReadError;
    }
    std::ofstream outFile;
#ifdef _WIN32
    outFile.open(Utf8ToWide(path).c_str(), std::ios::binary | std::ios::out);
#else
    outFile.open(path, std::ios::binary | std::ios::out);
#endif
    if (!outFile.is_open() || !outFile.good()) {
      return kArchiveOpenError;
    }
    outFile.write(reinterpret_cast<const char *>(outBuffer + offset), static_cast<std::streamsize>(outSizeProcessed));
    // A full disk fails the write (or the flush on close): report it rather
    // than hand back a truncated file as extracted.
    const bool written = outFile.good();
    outFile.close();
    if (!written || outFile.fail()) {
      return kArchiveWriteError;
    }
    return kArchiveOK;
  }
};

FFI_PLUGIN_EXPORT void freeArchiveFile(const ArchiveFile archive) {
  delete[] archive.name;
}

FFI_PLUGIN_EXPORT void* openArchive(const char* path) {
  return new Archive{path};
}

FFI_PLUGIN_EXPORT ArchiveStatus checkArchiveStatus(void* archive) {
  const auto a = static_cast<Archive *>(archive);
  return a->status;
}

FFI_PLUGIN_EXPORT void closeArchive(void* archive) {
  delete static_cast<Archive *>(archive);
}

FFI_PLUGIN_EXPORT uint32_t getArchiveFileCount(void* archive) {
  const auto a = static_cast<Archive *>(archive);
  return a->numFiles();
}

FFI_PLUGIN_EXPORT ArchiveFile getArchiveFile(void* archive, uint32_t index) {
  const auto a = static_cast<Archive *>(archive);
  return a->getFileByIndex(index);
}

FFI_PLUGIN_EXPORT unsigned char* readArchiveFile(void* archive, uint32_t index) {
  const auto a = static_cast<Archive *>(archive);
  return a->readFile(index);
}
FFI_PLUGIN_EXPORT void freeReadData(void* p) {
  delete[] static_cast<unsigned char *>(p);
}

FFI_PLUGIN_EXPORT ArchiveStatus extractArchiveToFile(void* archive, uint32_t index, const char* path) {
  const auto a = static_cast<Archive *>(archive);
  return a->extractFileToPath(index, path);
}
