#!/usr/bin/env bats

setup() {
    EXPORTER="${BATS_TEST_DIRNAME}/../lab/export-deploy-master.sh"
}

@test "Hyper-V-only export is discoverable and skips conversion tooling" {
    run bash "$EXPORTER" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--hyperv-only"* ]]
    grep -q 'if \[\[ \$HYPERV_ONLY -eq 0 \]\]' "$EXPORTER"
    grep -q 'Done. Hyper-V test artifact' "$EXPORTER"
}

@test "export refuses to overwrite the versioned VHDX" {
    grep -q 'Refusing to overwrite existing artifact' "$EXPORTER"
}
