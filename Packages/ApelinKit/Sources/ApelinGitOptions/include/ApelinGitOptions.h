#ifndef APELIN_GIT_OPTIONS_H
#define APELIN_GIT_OPTIONS_H

// libgit2's library options are set through `git_libgit2_opts`, a variadic
// function, which Swift cannot call. These two take one integer option each.

/// `git_libgit2_opts(option, value)`.
int apelin_git_set_option(int option, int value);

/// `git_libgit2_opts(option, &value)`.
int apelin_git_get_option(int option, int *value);

#endif
