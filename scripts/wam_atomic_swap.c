#define _DARWIN_C_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

struct Identity {
  dev_t device;
  ino_t inode;
};

static bool decimal_identity_text(const char* value) {
  if (value[0] == '\0') {
    return false;
  }
  for (const unsigned char* cursor = (const unsigned char*)value;
       *cursor != 0U; ++cursor) {
    if (*cursor < (unsigned char)'0' || *cursor > (unsigned char)'9') {
      return false;
    }
  }
  return true;
}

static int parse_identity(const char* device_text, const char* inode_text,
                          struct Identity* result) {
  if (!decimal_identity_text(device_text) ||
      !decimal_identity_text(inode_text)) {
    return -1;
  }
  char* end = NULL;
  errno = 0;
  const unsigned long long device = strtoull(device_text, &end, 10);
  if (errno != 0 || end == device_text || *end != '\0') {
    return -1;
  }
  errno = 0;
  const unsigned long long inode = strtoull(inode_text, &end, 10);
  if (errno != 0 || end == inode_text || *end != '\0') {
    return -1;
  }
  result->device = (dev_t)device;
  result->inode = (ino_t)inode;
  if ((unsigned long long)result->device != device ||
      (unsigned long long)result->inode != inode) {
    return -1;
  }
  return 0;
}

static bool safe_leaf_name(const char* value) {
  return value[0] != '\0' && strcmp(value, ".") != 0 &&
         strcmp(value, "..") != 0 && strchr(value, '/') == NULL;
}

static bool identity_matches(const struct stat* value,
                             struct Identity expected) {
  return value->st_dev == expected.device && value->st_ino == expected.inode;
}

static bool directory_identity_matches(const struct stat* value,
                                       struct Identity expected) {
  return S_ISDIR(value->st_mode) && identity_matches(value, expected);
}

static bool regular_identity_matches(const struct stat* value,
                                     struct Identity expected) {
  return S_ISREG(value->st_mode) && identity_matches(value, expected);
}

static int read_child(int parent, const char* name, struct stat* value) {
  return fstatat(parent, name, value, AT_SYMLINK_NOFOLLOW);
}

static bool verify_parent(int descriptor, struct Identity expected) {
  struct stat value;
  return fstat(descriptor, &value) == 0 &&
         directory_identity_matches(&value, expected);
}

static bool verify_pair(int final_parent, const char* final_name,
                        struct Identity final_expected, int stage_parent,
                        const char* stage_name,
                        struct Identity stage_expected) {
  struct stat final_value;
  struct stat stage_value;
  return read_child(final_parent, final_name, &final_value) == 0 &&
         read_child(stage_parent, stage_name, &stage_value) == 0 &&
         directory_identity_matches(&final_value, final_expected) &&
         directory_identity_matches(&stage_value, stage_expected);
}

static int close_pair(int first, int second, int status) {
  const int first_status = first < 0 ? 0 : close(first);
  const int second_status = second < 0 ? 0 : close(second);
  if ((first_status != 0 || second_status != 0) && status == 0) {
    fputs("atomic helper could not close an anchored directory\n", stderr);
    return 3;
  }
  return status;
}

static int remove_directory_contents(int directory);

static int remove_exact_directory(int parent, const char* name,
                                  struct Identity expected) {
  struct stat before;
  struct stat opened;
  struct stat after;
  if (read_child(parent, name, &before) != 0 ||
      !directory_identity_matches(&before, expected)) {
    return -1;
  }
  const int child =
      openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (child < 0 || fstat(child, &opened) != 0 ||
      !directory_identity_matches(&opened, expected)) {
    if (child >= 0) {
      (void)close(child);
    }
    return -1;
  }
  if (remove_directory_contents(child) != 0 ||
      read_child(parent, name, &after) != 0 ||
      !directory_identity_matches(&after, expected) ||
      !identity_matches(&after, (struct Identity){opened.st_dev, opened.st_ino})) {
    (void)close(child);
    return -1;
  }
  if (unlinkat(parent, name, AT_REMOVEDIR) != 0) {
    (void)close(child);
    return -1;
  }
  return close(child) == 0 ? 0 : -1;
}

static int remove_exact_regular(int parent, const char* name,
                                struct Identity expected) {
  struct stat before;
  struct stat opened;
  struct stat after;
  if (read_child(parent, name, &before) != 0 ||
      !regular_identity_matches(&before, expected)) {
    return -1;
  }
  const int child = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (child < 0 || fstat(child, &opened) != 0 ||
      !regular_identity_matches(&opened, expected) ||
      read_child(parent, name, &after) != 0 ||
      !regular_identity_matches(&after, expected) ||
      !identity_matches(&after, (struct Identity){opened.st_dev, opened.st_ino})) {
    if (child >= 0) {
      (void)close(child);
    }
    return -1;
  }
  if (unlinkat(parent, name, 0) != 0) {
    (void)close(child);
    return -1;
  }
  return close(child) == 0 ? 0 : -1;
}

static int remove_untrusted_leaf(int parent, const char* name,
                                 const struct stat* expected) {
  struct stat opened;
  struct stat after;
  if (S_ISLNK(expected->st_mode)) {
    if (read_child(parent, name, &after) != 0 ||
        !identity_matches(&after, (struct Identity){expected->st_dev,
                                                    expected->st_ino}) ||
        !S_ISLNK(after.st_mode)) {
      return -1;
    }
    return unlinkat(parent, name, 0);
  }
  if (S_ISDIR(expected->st_mode)) {
    return remove_exact_directory(
        parent, name, (struct Identity){expected->st_dev, expected->st_ino});
  }
  if (!S_ISREG(expected->st_mode)) {
    return -1;
  }
  const int child = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (child < 0 || fstat(child, &opened) != 0 ||
      !regular_identity_matches(
          &opened, (struct Identity){expected->st_dev, expected->st_ino}) ||
      read_child(parent, name, &after) != 0 ||
      !regular_identity_matches(
          &after, (struct Identity){expected->st_dev, expected->st_ino})) {
    if (child >= 0) {
      (void)close(child);
    }
    return -1;
  }
  if (unlinkat(parent, name, 0) != 0) {
    (void)close(child);
    return -1;
  }
  return close(child) == 0 ? 0 : -1;
}

static int remove_directory_contents(int directory) {
  const int scan_descriptor = dup(directory);
  if (scan_descriptor < 0) {
    return -1;
  }
  DIR* const stream = fdopendir(scan_descriptor);
  if (stream == NULL) {
    (void)close(scan_descriptor);
    return -1;
  }
  int status = 0;
  errno = 0;
  for (;;) {
    struct dirent* const entry = readdir(stream);
    if (entry == NULL) {
      if (errno != 0) {
        status = -1;
      }
      break;
    }
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      errno = 0;
      continue;
    }
    struct stat child;
    if (read_child(directory, entry->d_name, &child) != 0 ||
        remove_untrusted_leaf(directory, entry->d_name, &child) != 0) {
      status = -1;
      break;
    }
    errno = 0;
  }
  if (closedir(stream) != 0) {
    status = -1;
  }
  return status;
}

static int verify_cleanup_inventory(int stage, const char* app_name,
                                    struct Identity app_expected,
                                    const char* helper_name,
                                    struct Identity helper_expected) {
  const int scan_descriptor = dup(stage);
  if (scan_descriptor < 0) {
    return -1;
  }
  DIR* const stream = fdopendir(scan_descriptor);
  if (stream == NULL) {
    (void)close(scan_descriptor);
    return -1;
  }
  bool saw_app = false;
  bool saw_helper = false;
  int status = 0;
  errno = 0;
  for (;;) {
    struct dirent* const entry = readdir(stream);
    if (entry == NULL) {
      if (errno != 0) {
        status = -1;
      }
      break;
    }
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      errno = 0;
      continue;
    }
    struct stat child;
    if (read_child(stage, entry->d_name, &child) != 0) {
      status = -1;
      break;
    }
    if (strcmp(entry->d_name, app_name) == 0 &&
        directory_identity_matches(&child, app_expected)) {
      saw_app = true;
    } else if (strcmp(entry->d_name, helper_name) == 0 &&
               regular_identity_matches(&child, helper_expected)) {
      saw_helper = true;
    } else {
      status = -1;
      break;
    }
    errno = 0;
  }
  if (closedir(stream) != 0) {
    status = -1;
  }
  return status == 0 && saw_app && saw_helper ? 0 : -1;
}

static int cleanup_stage(int argc, char** argv) {
  if (argc != 14 || !safe_leaf_name(argv[3]) ||
      !safe_leaf_name(argv[8]) || !safe_leaf_name(argv[11])) {
    fputs("usage: wam_atomic_swap cleanup PARENT STAGE PARENT_DEV PARENT_INO "
          "STAGE_DEV STAGE_INO APP APP_DEV APP_INO HELPER HELPER_DEV "
          "HELPER_INO\n",
          stderr);
    return 64;
  }
  struct Identity parent_expected;
  struct Identity stage_expected;
  struct Identity app_expected;
  struct Identity helper_expected;
  if (parse_identity(argv[4], argv[5], &parent_expected) != 0 ||
      parse_identity(argv[6], argv[7], &stage_expected) != 0 ||
      parse_identity(argv[9], argv[10], &app_expected) != 0 ||
      parse_identity(argv[12], argv[13], &helper_expected) != 0) {
    fputs("stage cleanup received an invalid identity\n", stderr);
    return 64;
  }

  const int parent =
      open(argv[2], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (parent < 0 || !verify_parent(parent, parent_expected)) {
    fputs("stage cleanup parent identity precheck failed\n", stderr);
    if (parent >= 0) {
      (void)close(parent);
    }
    return 1;
  }
  struct stat stage_path;
  if (read_child(parent, argv[3], &stage_path) != 0 ||
      !directory_identity_matches(&stage_path, stage_expected)) {
    fputs("unrecognized packaging stage retained\n", stderr);
    return close_pair(parent, -1, 1);
  }
  const int stage = openat(parent, argv[3],
                           O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (stage < 0 || !verify_parent(stage, stage_expected) ||
      verify_cleanup_inventory(stage, argv[8], app_expected, argv[11],
                               helper_expected) != 0) {
    fputs("unrecognized packaging stage contents retained\n", stderr);
    return close_pair(parent, stage, 1);
  }

  if (remove_exact_directory(stage, argv[8], app_expected) != 0 ||
      remove_exact_regular(stage, argv[11], helper_expected) != 0) {
    fputs("could not clean the identity-checked packaging stage\n", stderr);
    return close_pair(parent, stage, 1);
  }
  if (close(stage) != 0) {
    fputs("could not close the identity-checked packaging stage\n", stderr);
    return close_pair(parent, -1, 1);
  }
  if (read_child(parent, argv[3], &stage_path) != 0 ||
      !directory_identity_matches(&stage_path, stage_expected) ||
      unlinkat(parent, argv[3], AT_REMOVEDIR) != 0) {
    fputs("empty but unrecognized packaging stage retained\n", stderr);
    return close_pair(parent, -1, 1);
  }
  return close_pair(parent, -1, 0);
}

static int swap_apps(int argc, char** argv, bool force_rollback) {
  if (argc != 14 || !safe_leaf_name(argv[3]) || !safe_leaf_name(argv[9])) {
    fputs("usage: wam_atomic_swap swap FINAL_PARENT FINAL_NAME "
          "FINAL_PARENT_DEV FINAL_PARENT_INO FINAL_DEV FINAL_INO "
          "STAGE_PARENT STAGE_NAME STAGE_PARENT_DEV STAGE_PARENT_INO "
          "STAGE_DEV STAGE_INO\n",
          stderr);
    return 64;
  }

  struct Identity final_parent_expected;
  struct Identity final_expected;
  struct Identity stage_parent_expected;
  struct Identity stage_expected;
  if (parse_identity(argv[4], argv[5], &final_parent_expected) != 0 ||
      parse_identity(argv[6], argv[7], &final_expected) != 0 ||
      parse_identity(argv[10], argv[11], &stage_parent_expected) != 0 ||
      parse_identity(argv[12], argv[13], &stage_expected) != 0) {
    fputs("atomic app swap received an invalid identity\n", stderr);
    return 64;
  }
  if (final_expected.device != stage_expected.device) {
    fputs("atomic app swap paths are not on one device\n", stderr);
    return 64;
  }

  const int final_parent =
      open(argv[2], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  const int stage_parent =
      open(argv[8], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (final_parent < 0 || stage_parent < 0 ||
      !verify_parent(final_parent, final_parent_expected) ||
      !verify_parent(stage_parent, stage_parent_expected) ||
      !verify_pair(final_parent, argv[3], final_expected, stage_parent,
                   argv[9], stage_expected)) {
    fputs("atomic app swap identity precheck failed\n", stderr);
    return close_pair(final_parent, stage_parent, 1);
  }

  if (renameatx_np(final_parent, argv[3], stage_parent, argv[9],
                   RENAME_SWAP) != 0) {
    fprintf(stderr, "atomic app swap failed: %s\n", strerror(errno));
    return close_pair(final_parent, stage_parent, 1);
  }

  const bool swapped_pair_is_exact =
      verify_parent(final_parent, final_parent_expected) &&
      verify_parent(stage_parent, stage_parent_expected) &&
      verify_pair(final_parent, argv[3], stage_expected, stage_parent, argv[9],
                  final_expected);
  if (swapped_pair_is_exact && !force_rollback) {
    return close_pair(final_parent, stage_parent, 0);
  }

  /* Roll back only while both descriptor-anchored names still identify the
     exact swapped pair. If either name is unrecognized, touching it could
     destroy foreign data. */
  if (swapped_pair_is_exact &&
      renameatx_np(final_parent, argv[3], stage_parent, argv[9], RENAME_SWAP) ==
          0 &&
      verify_parent(final_parent, final_parent_expected) &&
      verify_parent(stage_parent, stage_parent_expected) &&
      verify_pair(final_parent, argv[3], final_expected, stage_parent, argv[9],
                  stage_expected)) {
    fputs("atomic app swap rolled back to the original app\n", stderr);
    return close_pair(final_parent, stage_parent, 2);
  }

  fputs("atomic app swap postcheck failed with unrecognized paths\n", stderr);
  return close_pair(final_parent, stage_parent, 3);
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fputs("wam_atomic_swap requires an explicit mode\n", stderr);
    return 64;
  }
  if (strcmp(argv[1], "swap") == 0) {
    return swap_apps(argc, argv, false);
  }
  if (strcmp(argv[1], "swap-rollback-test") == 0) {
    return swap_apps(argc, argv, true);
  }
  if (strcmp(argv[1], "cleanup") == 0) {
    return cleanup_stage(argc, argv);
  }
  fputs("wam_atomic_swap received an unknown mode\n", stderr);
  return 64;
}
