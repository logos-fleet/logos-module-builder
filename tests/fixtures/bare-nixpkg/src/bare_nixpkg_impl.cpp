#include "bare_nixpkg_impl.h"

#include <boost/uuid/uuid.hpp>
#include <boost/uuid/uuid_generators.hpp>
#include <boost/uuid/uuid_io.hpp>

std::string BareNixpkgImpl::uuid()
{
    static boost::uuids::random_generator gen;
    return boost::uuids::to_string(gen());
}
