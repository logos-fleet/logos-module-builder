#include "bare_extlib_impl.h"

#include <greet.h>

int64_t BareExtlibImpl::answer()
{
    return greet_answer();
}
