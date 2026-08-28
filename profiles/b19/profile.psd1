@{
    SchemaVersion = 2
    Name = 'B19'
    TitleId = '454108D8'
    MediaId = '44388CF4'
    TitleModuleHash = '7C5F016EA6A81E95'
    XeniaSha256 = 'B19F51D4D6C3730C6D7D998B4A0D75C0A5A2D911260829C47C6728E3AD464B06'
    # Mutable launchers accept only hashes promoted into this list after a
    # controlled same-PC runtime acceptance. The source-built candidate below
    # remains deliberately excluded until that separate experiment passes.
    AcceptedRuntimeXeniaSha256 = @(
        'B19F51D4D6C3730C6D7D998B4A0D75C0A5A2D911260829C47C6728E3AD464B06'
    )
    XeniaConfigFileName = 'xenia-canary-netplay.config.toml'
    PortableRuntimeCandidate = @{
        Evidence = 'NOT RUNTIME-TESTED AS A PORTABLE LAUNCHER'
        SourceBuiltXeniaSha256 = '9A02C2C9DD63FAB9C9BB9AFF193D60C389F52606EBA1B8EB54963D15F11007ED'
        XwsMainSha256 = '10D4C6B7C99EC423D875E69195D378EA304077A489001C5F286B797BA00CF63E'
        ClearSessionsSha256 = '4C96DCE9C8CA0012E7FE17EDD7E522F4448EBC227E45E304CB3AE907117681B1'
        FeslSha256 = 'B9711B60EE3B28EE75E0EFBE1DF304EA46087F3ED7AD99DF97AF93C85867747E'
    }
    ApplyPatchesRequired = $true

    SupportedGame = @{
        IsoBytes = 7838695424
        IsoSha256 = '7C2008F53D4569D4079311B36CF2555E5FDC26B48A2C2E3578580B9F07EC16EF'
        DefaultXexBytes = 9379840
        DefaultXexSha256 = 'F9BBB0D9EE15A6E3628BFB273D1F93DDA9F8148E5E96B1B18B1F094CF23227F8'
        TitleUpdate = 'None'
    }

    Daddy = @{
        Template = 'daddy.launch.template.txt'
        TemplateSha256 = '26C44B74511E80238042F61C095976A03089DBCBF65E31A7DCD02CDA78A952DF'
        FrozenLineSha256 = '2C604E2C124AE9485E716AC615F64EF6B9760CA52D160FAB15A09D1A09744BC6'
        FrozenTokenCount = 230
        FrozenOptionCount = 229
        FrozenBreakPcCount = 605
        FrozenInvertRightX = $true
    }

    Cj = @{
        Template = 'cj.launch.template.txt'
        TemplateSha256 = '8E9122E972389EAFA0701DA7BFC1C301043FF490049334EC70901B743145CEBC'
        FrozenLineSha256 = '72C1B51FBFFACEAFF9940EE24FFECE831DDB1868E10A344584258704E6DC4CFB'
        FrozenTokenCount = 230
        FrozenOptionCount = 229
        FrozenBreakPcCount = 626
        FrozenInvertRightX = $false
    }

    # These three blocks were enabled in the successful frozen B19 profile and
    # are treated as profile requirements until later per-patch ablation.
    FrozenProfileCoopPatches = @(
        @{
            FileName = '454108D8 - coop-bind-6000.patch.toml'
            Sha256 = 'BCD3F9A62106424908DA3AD8B543D1A482D4C4561DCCBF26D8EBE99A8CFBE295'
            FrozenRigSha256 = '8E4AD2F88B5A8C1545583FA770FDCA2D42F716FD8F5FE7C4691BD3B59276BBE9'
            PatchName = 'Coop - bind real UDP :6000 (same-PC loopback shim)'
            Type = 'be32'
            Address = '0x82322AF8'
            Value = '0x4800003C'
        }
        @{
            FileName = '454108D8 - coop-cod-unaddressed.patch.toml'
            Sha256 = 'F5CC6083791194E48106E4DE7D6D31C061BAFB43FA90EE935A56698398BC5036'
            FrozenRigSha256 = 'C6A4A05163B7870D0A0E856D1BE3381B5D27E2D200292A33CC2DAC697E607285'
            PatchName = 'Coop - force unaddressed COd framing (same-PC handshake shim)'
            Type = 'be32'
            Address = '0x8239D6C0'
            Value = '0x39600000'
        }
        @{
            FileName = '454108D8 - coop-hold-connecting-v2.patch.toml'
            Sha256 = 'F01126934D5CE6E7DBC9D3C51D3F119DA7C50684B83AF838B4C3C8ED22497440'
            FrozenRigSha256 = '27FC975992EC57A3E7022EBBA7FEC73CB9798C0621BF88E1196B430F427F2482'
            PatchName = 'Coop - HOLD at CONNECTING v2 (branch-scoped give-up no-op)'
            Type = 'be32'
            Address = '0x82C86A48'
            Value = '0x480001C8'
        }
    )

    FrozenVisualPatch = @{
        FileName = '454108D8 - Army of Two The 40th Day.patch.toml'
        Sha256 = 'AA94E1E7BEDB461421AB581769EE6DAC5F177586B64964195A1BC2DC20D297C7'
        Distribution = 'NotBundledLicenseUnresolved'
        EnabledNames = @(
            'Unlock FPS'
            '16x Anisotropic Filtering'
            'Disable FSAA (Full-Screen Anti-Aliasing)'
        )
    }
}
