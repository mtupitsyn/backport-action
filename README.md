# backport-action

GitHub Action to backport pull requests.

Put this in your `.github/workflows/backport.yml`:

```yml
name: Backport

on:
  pull_request:
    types:
      - closed
      - labeled

jobs:
  backport:
    runs-on: ubuntu-latest
    name: Backport closed pull request
    steps:
    - uses: syndesisio/backport-action@v1
```

And for each pull request that needs to be backported to branch `<branch>` add a `backport <branch>` label on the pull request.

This fork of original syndesisio/backport-action@v1 also supports dry run of cherry-pick, before the PR is actually merged.
To invoke dry run, use atrix strategy (i.e. separate job for each label, assigned to PR). To tell plugin to use branch from
a matrix scope, instead of iterating over labels, use `BACKPORT_LABEL` environment variable:

```yml
name: Backport

on:
  pull_request:
    types:
      - closed
      - labeled
      - unlabeled

jobs:
  backport:
    if: ${{ github.event.pull_request.labels != '[]' && github.event.pull_request.labels != '' }}
    strategy:
      matrix:
        label: ${{github.event.pull_request.labels.*.name}}
      fail-fast: false
    runs-on: ubuntu-latest
    steps:
    - name: ${{ matrix.label }}
      env:
        BACKPORT_LABEL: ${{ matrix.label }}
        BACKPORT_REPORT_FAILURE: ${{ github.event_name == 'pull_request' && github.event.action == 'closed' }}
      uses: Cray-HPE/backport-action@v2
```