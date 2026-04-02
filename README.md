# interop-testing
Repository for interop testing between operators

## The `OWNERS` and `OWNERS_ALIASES`
The `OWNERS` file will be synced to https://github.com/openshift/release/blob/main/ci-operator/config/RedHatQE/interop-testing/OWNERS.
It may contain Group Aliases from https://github.com/openshift/release/blob/main/OWNERS_ALIASES, as long as the `OWNERS_ALIASES` is updated with this script:
```shell
# Run this on the `root` of `git` local Working Tree.
(
    curl -fsSL 'https://raw.githubusercontent.com/openshift/release/main/OWNERS_ALIASES' |
    yq -o json '.aliases' |
    jq --argjson names "$(yq -o json 'explode(.) | [.approvers[], .reviewers[]] | unique' OWNERS)" '
        {"aliases": with_entries(select(.key | IN($names[])))}
    ' |
    yq -p json -o yaml '
        . head_comment=(
            "See the OWNERS_ALIASES docs: https://git.k8s.io/community/contributors/guide/owners.md#owners_aliases" +
            "\nRead `README.md` on how to update this file!!!"
        )
    '
) > OWNERS_ALIASES
```