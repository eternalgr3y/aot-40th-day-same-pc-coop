@{
    SchemaVersion = 1
    Name = 'B19-Runtime-Core-Acceptance'
    ArtifactClass = 'OFFLINE_ACCEPTANCE_PLAN_NOT_PLAYER_KIT'
    PlayerKitReady = $false
    RuntimeTested = $false
    LaunchCapable = $false

    SourceCommit = 'b8c0c49520e841a97309e7c742570c0a8769c4f6'
    SourceTree = '1194169c7723b1bbf314105c5255a7ea2e2e7c97'
    XeniaBytes = 17942016
    XeniaSha256 = 'E0AE2C785BC19637E83019FE921E0D3CEE83B229D1CDF9B82F6508A50336C629'

    TitleId = '454108D8'
    MediaId = '44388CF4'
    TitleModuleHash = '7C5F016EA6A81E95'
    SupportedGame = @{
        IsoBytes = 7838695424
        IsoSha256 = '7C2008F53D4569D4079311B36CF2555E5FDC26B48A2C2E3578580B9F07EC16EF'
        DefaultXexBytes = 9379840
        DefaultXexSha256 = 'F9BBB0D9EE15A6E3628BFB273D1F93DDA9F8148E5E96B1B18B1F094CF23227F8'
        TitleUpdate = 'None'
    }

    AllowedAotOptions = @(
        'aot_runtime_peer_ipv4'
        'aot_runtime_sa2'
        'aot_runtime_leg_destination_repair'
        'aot_runtime_xport_control_load_repair'
    )

    RequiredPatches = @(
        @{
            FileName = '454108D8 - coop-bind-6000.patch.toml'
            Sha256 = 'BCD3F9A62106424908DA3AD8B543D1A482D4C4561DCCBF26D8EBE99A8CFBE295'
            PatchName = 'Coop - bind real UDP :6000 (same-PC loopback shim)'
            Type = 'be32'
            Address = '0x82322AF8'
            Value = '0x4800003C'
        }
        @{
            FileName = '454108D8 - coop-cod-unaddressed.patch.toml'
            Sha256 = 'F5CC6083791194E48106E4DE7D6D31C061BAFB43FA90EE935A56698398BC5036'
            PatchName = 'Coop - force unaddressed COd framing (same-PC handshake shim)'
            Type = 'be32'
            Address = '0x8239D6C0'
            Value = '0x39600000'
        }
        @{
            FileName = '454108D8 - coop-hold-connecting-v2.patch.toml'
            Sha256 = 'F01126934D5CE6E7DBC9D3C51D3F119DA7C50684B83AF838B4C3C8ED22497440'
            PatchName = 'Coop - HOLD at CONNECTING v2 (branch-scoped give-up no-op)'
            Type = 'be32'
            Address = '0x82C86A48'
            Value = '0x480001C8'
        }
    )

    PendingRuntimeGates = @(
        'ZERO_LIVE_XENIA_PROCESSES_BEFORE_STAGING'
        'VERIFIED_SAVE_BACKUP_COMPLETED_BEFORE_ACCEPTANCE_RUN_PREP'
        'ISOLATED_RIG_ROOTS_CREATED_WITHOUT_OVERWRITE'
        'DADDY_SLOT_1_OCCUPIED_AND_CJ_SLOT_2_VERIFIED_EMPTY'
        'LIVE_CPU_TOPOLOGY_MATCHES_DECLARED_SIGNATURE'
        'RIG_XCONFIG_IDENTITIES_MATCH_DECLARED_VALUES'
        'TWO_PHYSICAL_PADS_PRESENT_AND_ISOLATED'
        'XWS_WHOAMI_IS_NONZERO_AND_BACKEND_IS_HEALTHY_BEFORE_JOIN'
        'SA2_BOTH_SIDES_EMIT_EXACTLY_ONE_MANAGER_ARM_MARKER'
        'SA2_ONE_SIDE_PROVES_GENERATION_BOUND_PREPARE_ARM_CONSUME_ACK_CHAIN'
        'EXTERNAL_TIMEOUT_AND_CLEANUP_ARE_ENFORCED'
        'NATIVE_JOIN_REACHES_ONE_SHARED_SESSION'
        'PHYSICAL_PAD_GAMEPLAY_IS_STABLE_FOR_THREE_MINUTES'
        'DEATH_CHECKPOINT_RELOAD_COMPLETES_WITHOUT_BACKEND_DISCONNECT'
    )

    RequiredSa2AcceptanceMarkers = @(
        @{
            Stage = 1
            Event = 'PRECONNECT_XSA1_PREPARED_FOR_GUEST'
            Format = '[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=1 event=PRECONNECT_XSA1_PREPARED_FOR_GUEST'
        }
        @{
            Stage = 2
            Event = 'XNETCONNECT_MANAGER_ARMED'
            Format = '[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=2 event=XNETCONNECT_MANAGER_ARMED'
        }
        @{
            Stage = 3
            Event = 'POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT'
            Format = '[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=3 event=POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT'
        }
    )

    Daddy = @{
        Template = 'daddy.arguments.template.txt'
        TemplateSha256 = 'FCDFFB2CB25300BF32D19AE64DB62A7343FF330EA4FFF9A22390AA8B7738FB2E'
        BaseArgumentCount = 16
        BaseOptionCount = 15
    }
    Cj = @{
        Template = 'cj.arguments.template.txt'
        TemplateSha256 = 'FCDFFB2CB25300BF32D19AE64DB62A7343FF330EA4FFF9A22390AA8B7738FB2E'
        BaseArgumentCount = 16
        BaseOptionCount = 15
    }
}
