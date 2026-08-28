@{
    SchemaVersion = 1
    Name = 'AoT-Coop-B19-Portable-Runtime-Source-Candidate'
    ArtifactClass = 'SOURCE_RUNTIME_CANDIDATE_NOT_PLAYER_KIT'
    PlayerKitReady = $false
    RuntimeTested = $false
    SnapshotSource = 'GIT_INDEX_STAGE_0'

    # This is a reviewable source snapshot, not a redistributable player kit.
    # Every path must exist as a stage-0 Git index entry before the snapshot
    # test will extract it. Machine-local configs and runtime artifacts are
    # deliberately absent.
    Files = @(
        'README.md'
        'LICENSE'
        'PACKAGING.md'
        'PUBLIC_ALPHA.md'
        'PROFILE_BOOTSTRAP.md'
        'ALPHA_MANIFEST.md'
        'THIRD_PARTY_NOTICES.md'
        '.gitattributes'
        '.github/workflows/validate-source-alpha.yml'
        'docs/b19_same_pc_physical_acceptance_20260826.md'
        'PLAY-AOT-COOP.cmd'
        'Start-AOT-Coop.ps1'
        'Setup-AOT-Coop.ps1'
        'aot-coop.portable.example.psd1'

        'profiles/b19/profile.psd1'
        'profiles/b19/daddy.launch.template.txt'
        'profiles/b19/cj.launch.template.txt'
        'profiles/b19/patches/454108D8 - coop-bind-6000.patch.toml'
        'profiles/b19/patches/454108D8 - coop-cod-unaddressed.patch.toml'
        'profiles/b19/patches/454108D8 - coop-hold-connecting-v2.patch.toml'

        'tools/runtime/AotPortableHardware.psm1'
        'tools/runtime/New-AotPortableLaunchPlan.ps1'
        'tools/runtime/backup_retail_acceptance_saves.ps1'
        'tools/runtime/confirm_daddy_continue.ps1'
        'tools/runtime/confirm_cj_empty_slot.ps1'
        'tools/runtime/fesl_server.py'
        'tools/runtime/test_service_contract.ps1'
        'tools/runtime/test_xws_session_gate.ps1'
        'tools/release/New-AotPublicSourceSnapshot.ps1'

        # Live Daddy gating reaches all three UI helpers transitively.
        'classify_screen.ps1'
        'dump_aot_ui.ps1'
        'tools/runtime/aot_top_level_window.ps1'

        'tests/test_portable_launch_plan.ps1'
        'tests/test_portable_hardware.ps1'
        'tests/test_portable_save_backup.ps1'
        'tests/test_public_source_snapshot.ps1'
        'tests/test_setup_aot_coop.ps1'
        'tests/test_start_aot_coop.ps1'
        'tests/test_confirm_daddy_continue.ps1'
        'tests/test_confirm_cj_empty_slot.ps1'
        'tests/test_cj_armed_join_monitor.ps1'
        'tests/test_xws_session_gate.ps1'
        'tests/test_hidden_window_discovery.ps1'
        'tests/test_fesl_ecnl_transaction.py'
        'tests/test_fesl_game_lifecycle.py'
        'tests/test_host_self_egrq_transaction.py'
        'tests/test_portable_runtime_source_allowlist.ps1'
        'release/portable-runtime-source.allowlist.psd1'
        'release/public-source.gitignore'
    )

    RequiredExternalRuntimeArtifacts = @(
        'User-owned Army of Two game image and saves'
        'Frozen B19 Xenia executable or a separately accepted source build'
        'Xenia-WebServices commit bc2f6e27f40911fca2730ce5ac04ffc64c49351e with npm ci dependencies and npm run build output matching the pinned dist/helper hashes'
        'Node.js and Python runtimes selected in the machine-local config'
        'A MongoDB service exposing exactly one loopback-only listener on TCP 27017'
        '64-bit Windows PowerShell 5.1 on the target Windows PC'
        'Two independently initialized Xenia rig directories and profiles'
    )

    RequiredExcludedArtifacts = @(
        'aot-coop.local.psd1 and aot-coop.portable.psd1'
        'Xenia executables, source tree, profiles, Account files, GPDs, and saves'
        'Xenia-WebServices dist output, source tree, databases, and node_modules'
        'Game images, extracted game files, logs, screenshots, traces, and run directories'
        'Upstream visual patch with unresolved redistribution status'
    )
}
