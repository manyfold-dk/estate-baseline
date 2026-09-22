#!/usr/bin/env bats
#
# Fixtures build a scratch git repo + bare origin in $BATS_TEST_TMPDIR. The race
# cases simulate a concurrent deploy by having a second clone advance origin/main
# between the script's commit and its push.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/bump-deploy-tag.sh"
  export GITHUB_ACTIONS=true
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  WORK="$BATS_TEST_TMPDIR/work"
  IMAGE="ghcr.io/manyfold-dk/test/app"

  git init -q --bare "$ORIGIN"
  git init -q -b main "$WORK"
  cd "$WORK"
  git remote add origin "$ORIGIN"
  git config user.name "test"
  git config user.email "test@test"
  mkdir -p gitops/prod
  cat > gitops/prod/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: app
          image: ${IMAGE}:old  # pinned at release
EOF
  git add -A
  git commit -qm "init"
  git push -q -u origin main
  # Point the bare repo's HEAD at main so clones (advance_origin) can check it out.
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
}

# Advance origin/main from a separate clone (concurrent deploy). $1 = tag to set on
# the image line (empty = leave image untouched, just add an unrelated commit).
advance_origin() {
  other="$BATS_TEST_TMPDIR/other.$RANDOM"
  git clone -q "$ORIGIN" "$other"
  (
    cd "$other"
    git config user.name other
    git config user.email other@test
    if [ -n "${1:-}" ]; then
      sed -E "s#(image:[[:space:]]*${IMAGE}):[^[:space:]]+#\1:$1#" gitops/prod/deployment.yaml > dep.tmp
      mv dep.tmp gitops/prod/deployment.yaml
    else
      echo "concurrent $RANDOM" > marker.txt
    fi
    git add -A
    git commit -qm "concurrent change"
    git push -q origin main
  )
}

origin_image_tag() {
  git -C "$ORIGIN" show "main:gitops/prod/deployment.yaml" | sed -n -E 's#.*image:[[:space:]]*'"$IMAGE"':([^[:space:]]+).*#\1#p'
}

@test "single manifest: tag replaced, committed, pushed" {
  run "$SCRIPT" --app-name app --image-base "$IMAGE" --tag new1 --manifest gitops/prod/deployment.yaml
  [ "$status" -eq 0 ]
  [ "$(origin_image_tag)" = "new1" ]
}

@test "single manifest: trailing comment preserved" {
  run "$SCRIPT" --app-name app --image-base "$IMAGE" --tag new2 --manifest gitops/prod/deployment.yaml
  [ "$status" -eq 0 ]
  grep -q "image: ${IMAGE}:new2  # pinned at release" gitops/prod/deployment.yaml
}

@test "no-op when already at the target tag (no commit/push)" {
  before="$(git rev-parse HEAD)"
  run "$SCRIPT" --app-name app --image-base "$IMAGE" --tag old --manifest gitops/prod/deployment.yaml
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to commit"* ]]
  [ "$(git rev-parse HEAD)" = "$before" ]
}

@test "race: origin advances, script rebases and still pushes the tag" {
  advance_origin ""   # unrelated commit lands on origin first
  run "$SCRIPT" --app-name app --image-base "$IMAGE" --tag raced --manifest gitops/prod/deployment.yaml
  [ "$status" -eq 0 ]
  [[ "$output" == *"rebasing onto latest main"* ]]
  [ "$(origin_image_tag)" = "raced" ]
}

@test "race: origin already at target tag after reset -> success no-op" {
  advance_origin "winner"   # origin already carries the target tag
  run "$SCRIPT" --app-name app --image-base "$IMAGE" --tag winner --manifest gitops/prod/deployment.yaml
  [ "$status" -eq 0 ]
  [[ "$output" == *"already has the target tag"* ]]
  [ "$(origin_image_tag)" = "winner" ]
}

@test "manifest-dir flavour updates the deployment in the directory" {
  run "$SCRIPT" --app-name app --image-base "$IMAGE" --tag dirtag --manifest-dir gitops/prod
  [ "$status" -eq 0 ]
  [ "$(origin_image_tag)" = "dirtag" ]
}

@test "mutually exclusive --manifest and --manifest-dir rejected" {
  run "$SCRIPT" --app-name app --image-base "$IMAGE" --tag x --manifest gitops/prod/deployment.yaml --manifest-dir gitops/prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "refuses to run outside GitHub Actions" {
  unset GITHUB_ACTIONS
  run "$SCRIPT" --app-name app --image-base "$IMAGE" --tag x --manifest gitops/prod/deployment.yaml
  [ "$status" -ne 0 ]
  [[ "$output" == *"GitHub Actions only"* ]]
}
