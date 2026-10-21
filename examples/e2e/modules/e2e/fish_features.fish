# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# e2e_fish_features: Fish-specific shell features.
# Native Fish module exercising the Fish loader path.

function e2e_fish_loaded --description 'Report Fish e2e features status'
    set -l fish_version (fish --version 2>/dev/null | string replace -r '.*version (.*)' '$1')
    echo "fish features loaded: version=$fish_version universal_vars=$(set -U | count)"
end

# Set a global exported variable to demonstrate Fish variable scoping.
# Note: set -gx is global and non-persistent (does not write to fish_variables),
# consistent with side_effect=read-only metadata.
set -gx E2E_FISH_LOADED "true"
