#ifndef LOGOS_FIXTURE_GREETAUX_H
#define LOGOS_FIXTURE_GREETAUX_H

#ifdef __cplusplus
extern "C" {
#endif

/* THE SECOND LIBRARY IN THE SAME PACKAGE, and the point of it.
 *
 * `nix.external_libraries` names a PACKAGE (`greet`); a package may ship
 * several libraries under names of its own, and the module's CMakeLists links
 * them by THOSE names. package_manager's one entry installs
 * libpackage_manager_lib and liblgx; nothing is called lib<entry>. This is that
 * shape, minimally: the builder has to stage the target's build of libgreetaux
 * over the build-platform one even though "greetaux" appears nowhere in
 * metadata.json. */
int greet_aux(void);

#ifdef __cplusplus
}
#endif

#endif
