#include "bare_extlib_impl.h"

#include <greet.h>
#include <greetaux.h>

int64_t BareExtlibImpl::answer()
{
    // Both libraries of the one external PACKAGE, so a link that lost either
    // is a link that fails rather than a module that dies at dlopen.
    return greet_answer() + greet_aux();
}
