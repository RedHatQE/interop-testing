# interop-testing
Repository for Inter-operability Testing between Layered Products (Operators).

## The `OWNERS` and `OWNERS_ALIASES`
The `OWNERS` file will be synced to https://github.com/openshift/release/blob/main/ci-operator/config/RedHatQE/interop-testing/OWNERS.
It may contain Group Aliases from https://github.com/openshift/release/blob/main/OWNERS_ALIASES, as long as the `OWNERS_ALIASES` is updated with this script:
```shell
# Run this on the `root` of `git` local Working Tree.
(
    1>> OWNERS_ALIASES; exec 3< <(cat OWNERS_ALIASES); wait $!
    curl -fsSL 'https://raw.githubusercontent.com/openshift/release/main/OWNERS_ALIASES' |
    yq -o json '.aliases' |
    jq --argjson names "$(yq -o json '
        explode(.) | [.approvers[], .reviewers[], .emeritus_approvers[]] | unique
    ' OWNERS)" 'with_entries(select(.key | IN($names[])))' |
    yq -p json -o yaml eval '{"aliases": .}' |
    yq eval-all '(select(fileIndex==0) * select(fileIndex==1)) | . head_comment=""' /dev/fd/3 - |
    column -t -s '#' -o '#' |
    sed \
        -e '1i# See the OWNERS_ALIASES docs: https://git.k8s.io/community/contributors/guide/owners.md#owners_aliases' \
        -e '1i# Read `README.md` on how to update this file!!!' \
        -e 's/ *#$//' \
    1> OWNERS_ALIASES
    exec 3<&-
)
```
