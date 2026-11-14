#include "ApelinGitOptions.h"

// Declared here rather than read from libgit2's headers: the target then
// needs nothing of the framework to compile, and ApelinGit links both.
extern int git_libgit2_opts(int option, ...);

int apelin_git_set_option(int option, int value) {
    return git_libgit2_opts(option, value);
}

int apelin_git_get_option(int option, int *value) {
    return git_libgit2_opts(option, value);
}
