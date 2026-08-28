@{
    SchemaVersion = 2

    # Launch-plan schema only. Setup-AOT-Coop.ps1 currently validates this
    # foundation but does not yet create fresh Xenia profiles or saves.

    # May be any absolute directory. Relative rig paths below resolve here.
    InstallRoot = '<absolute path to the extracted AoT co-op alpha>'
    GamePath = '<absolute path to your legally obtained Army of Two ISO>'
    XeniaFileName = 'xenia_canary_netplay.exe'
    ApiAddress = 'http://127.0.0.1:36000/'

    # XWS may be a relative folder in a future player kit or an absolute path
    # to the pinned companion checkout. Node and Python are prerequisites.
    XwsRoot = 'services\xws'
    NodeExe = '<absolute path to node.exe>'
    PythonExe = '<absolute path to python.exe>'
    FeslSeconds = 86400

    # Generate these for the target PC with Setup-AOT-Coop.ps1. FESL uses one
    # of the cores reserved to XWS; neither service mask may overlap a rig.
    XwsCpuMask = '<topology-derived service CPU mask>'
    FeslCpuMask = '<topology-derived subset of XwsCpuMask>'
    CpuAllocationPolicy = 'WholeCoreTierSplitV1'
    CpuTopologySignature = '<64-hex signature reported by Setup-AOT-Coop.ps1>'
    ReservedCpuMask = '00000000'

    # SaveSlot configures Daddy's occupied middle checkpoint. CJ does not reuse
    # it: the runtime gate requires the verified-empty right SAVE_SLOT_2.
    SaveSlot = 1

    Daddy = @{
        RigDir = 'rigs\daddy'
        ProfileXuid = '<fresh local E000 plus 12 hex digits from this rig>'
        OnlineXuid = '<persisted 0009 plus 12 hex digits from this Live-enabled profile>'
        MacAddress = '<fresh 7C1E52 plus 6 hex digits from this rig>'
        HostAddress = '<127.x.y.z derived from the last three MAC bytes>'
        Controller = '<SDL route in 0xVVVV/0xPPPP form>'
        CpuMask = '<nonzero hexadecimal processor mask>'
        InvertRightX = $false
    }

    Cj = @{
        RigDir = 'rigs\cj'
        ProfileXuid = '<different local E000 plus 12 hex digits from this rig>'
        OnlineXuid = '<different persisted 0009 plus 12 hex digits>'
        MacAddress = '<different fresh 7C1E52 plus 6 hex digits>'
        HostAddress = '<different derived 127.x.y.z address>'
        Controller = '<different SDL 0xVVVV/0xPPPP route>'
        CpuMask = '<non-overlapping hexadecimal processor mask>'
        InvertRightX = $false
    }
}
