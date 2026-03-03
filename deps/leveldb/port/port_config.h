// Port config for POSIX builds (macOS + Linux).

#ifndef STORAGE_LEVELDB_PORT_PORT_CONFIG_H_
#define STORAGE_LEVELDB_PORT_PORT_CONFIG_H_

#if !defined(HAVE_FDATASYNC)
#if defined(__linux__)
#define HAVE_FDATASYNC 1
#else
#define HAVE_FDATASYNC 0
#endif
#endif

#if !defined(HAVE_FULLFSYNC)
#if defined(__APPLE__)
#define HAVE_FULLFSYNC 1
#else
#define HAVE_FULLFSYNC 0
#endif
#endif

#if !defined(HAVE_O_CLOEXEC)
#define HAVE_O_CLOEXEC 1
#endif

#if !defined(HAVE_CRC32C)
#define HAVE_CRC32C 0
#endif

#if !defined(HAVE_SNAPPY)
#define HAVE_SNAPPY 0
#endif

#endif  // STORAGE_LEVELDB_PORT_PORT_CONFIG_H_
