// Standalone bounded native regression. Build as net8.0 against a matching
// runtime and platform-lib; run in an isolated HOME. No firmware is required.
using System;
using System.Threading;
using System.Threading.Tasks;
using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;
using Antmicro.Renode.Peripherals.IRQControllers;
using Antmicro.Renode.Peripherals.Memory;
using Antmicro.Renode.Peripherals.Miscellaneous;
using Antmicro.Renode.Time;

public static class CortexMDebugHeldResetRepro
{
    static void Log(string text) { Console.WriteLine(DateTime.UtcNow.ToString("O") + " " + text); Console.Out.Flush(); }
    static void Need(bool condition, string reason) { if(!condition) throw new Exception(reason); }
    static uint Reg(CortexM cpu, int index) => (uint)cpu.GetRegister(index);
    sealed class ObservedCortexM : CortexM
    {
        public ObservedCortexM(string model, Machine machine, NVIC nvic, uint index, bool trustZone)
            : base(model, machine, nvic, cpuId: index, enableTrustZone: trustZone) { }
        public override void Reset() { base.Reset(); Interlocked.Increment(ref ResetCount); }
        public int ResetCount;
    }
    public static int Main(string[] args)
    {
        try { Run(); Log("PASS DEBUGGER_HELD_AIRCR_RESET"); Environment.Exit(0); return 0; }
        catch(Exception error) { Log("FAIL " + error); Environment.Exit(1); return 1; }
    }
    static void Run()
    {
        var emulation = EmulationManager.Instance.CurrentEmulation;
        emulation.MasterTimeSource.Quantum = TimeInterval.FromMicroseconds(10);
        var target = new Machine(createLocalTimeSource: true);
        var sibling = new Machine(createLocalTimeSource: true);
        target.LocalTimeSource.Quantum = sibling.LocalTimeSource.Quantum = TimeInterval.FromMicroseconds(10);
        emulation.AddMachine(target, "debug_reset_target"); emulation.AddMachine(sibling, "native_probe_peer");
        var ram = new MappedMemory(target, 0x4000);
        target.SystemBus.Register(ram, new BusPointRegistration(0x20000000));
        ram.WriteDoubleWord(0, 0x20003ff0); ram.WriteDoubleWord(4, 0x20000101);
        ram.WriteWord(0x100, 0x3001); ram.WriteWord(0x102, 0xe7fd); // adds r0, #1; b .-2
        // A fresh vector and first-instruction marker distinguish reset-and-hold
        // from old-PC continuation or a register-only reset acknowledgement.
        ram.WriteWord(0x200, 0x255a); // movs r5, #0x5a
        ram.WriteWord(0x202, 0x3001); ram.WriteWord(0x204, 0xe7fd);
        var cpus = new ObservedCortexM[2]; var nvics = new NVIC[2];
        for(int i = 0; i < 2; i++)
        {
            nvics[i] = new NVIC(target);
            cpus[i] = new ObservedCortexM("cortex-m33-rp2350", target, nvics[i], (uint)i, true);
            target.SystemBus.Register(cpus[i], new CPURegistrationPoint(i)); target.SetLocalName(cpus[i], "cpu" + i);
            target.SystemBus.Register(nvics[i], new BusPointRegistration(0xe000e000, cpu: cpus[i]));
            cpus[i].PerformanceInMips = 100; cpus[i].InitVectorTableOffset = 0x20000000; cpus[i].Reset();
        }
        var debugPort = new RP2350_DebugPort(target, cpus[0], cpus[1]);
        target.SystemBus.Register(debugPort, NullRegistrationPoint.Instance);
        var powman = new RP2350_POWMAN(target, cpus[0], cpus[1], nvics[0], nvics[1], debugPort);
        target.SystemBus.Register(powman, new BusRangeRegistration(0x40100000, 0x4000));
        nvics[0].SystemResetRequest.Connect(powman, 0); nvics[1].SystemResetRequest.Connect(powman, 1);

        var peerRam = new MappedMemory(sibling, 0x4000);
        sibling.SystemBus.Register(peerRam, new BusPointRegistration(0x20000000));
        peerRam.WriteDoubleWord(0, 0x20003ff0); peerRam.WriteDoubleWord(4, 0x20000101);
        peerRam.WriteWord(0x100, 0x3001); peerRam.WriteWord(0x102, 0xe7fd);
        var peerNVIC = new NVIC(sibling); var peer = new CortexM("cortex-m0+", sibling, peerNVIC);
        sibling.SystemBus.Register(peer, new CPURegistrationPoint(0)); sibling.SetLocalName(peer, "cpu");
        sibling.SystemBus.Register(peerNVIC, new BusPointRegistration(0xe000e000, cpu: peer));
        peer.PerformanceInMips = 100; peer.InitVectorTableOffset = 0x20000000; peer.Reset();
        target.PostCreationActions(); sibling.PostCreationActions();
        Action advance = () =>
        {
            var run = Task.Run(() => emulation.RunFor(TimeInterval.FromMicroseconds(100)));
            if(!run.Wait(3000))
            {
                Log("TIME_PROGRESS_FAILURE resetCount=" + Volatile.Read(ref cpus[0].ResetCount)
                    + " debuggerHeld=" + cpus[0].HaltedByDebugger + " paused=" + cpus[0].IsPaused
                    + " targetHandleEnabled=" + cpus[0].TimeHandle.Enabled
                    + " targetRetired=" + cpus[0].ExecutedInstructions);
                throw new Exception("Master time froze after resetting a debugger-held PE");
            }
        };
        Func<uint> dhcsr = () => target.SystemBus.ReadDoubleWord(0xe000edf0, cpus[0]);
        advance();
        Need(Reg(cpus[0], 0) > 100 && Reg(cpus[1], 0) > 100 && Reg(peer, 0) > 100,
            "Initial native code did not execute in all three PEs");
        Log("THREE_NATIVE_PES_EXECUTING_BEFORE_DEBUG_HALT");
        // Actual external debug controls, including reset vector catch.
        target.SystemBus.WriteDoubleWord(0xe000edfc, 1, cpus[0]);
        target.SystemBus.WriteDoubleWord(0xe000edf0, 0xa05f0003, cpus[0]);
        Need(SpinWait.SpinUntil(() => (dhcsr() & 0x20000) != 0, 3000), "DHCSR did not acknowledge an actual halt");
        Need(cpus[0].HaltedByDebugger, "S_HALT acknowledged without debugger-held PE");
        ulong heldBeforeReset = cpus[0].ExecutedInstructions;
        advance();
        Need(cpus[0].ExecutedInstructions == heldBeforeReset, "Debugger-held PE retired before warm reset");
        ram.WriteDoubleWord(0, 0x20003f00); ram.WriteDoubleWord(4, 0x20000201);
        int resets = Volatile.Read(ref cpus[0].ResetCount);
        // This is the production SystemBus -> NVIC SYSRESETREQ -> POWMAN path.
        target.SystemBus.WriteDoubleWord(0xe000ed0c, 0x05fa0004, cpus[0]);
        Log("AIRCR_WARM_RESET_REQUESTED_WHILE_C_HALT_SET");
        advance();
        Need(Volatile.Read(ref cpus[0].ResetCount) == resets + 1, "AIRCR did not execute a real core reset");
        Need(SpinWait.SpinUntil(() => (dhcsr() & 0x20000) != 0, 3000), "Vector catch halt did not acknowledge after reset");
        Need(cpus[0].HaltedByDebugger && (dhcsr() & 3) == 3, "Warm reset lost C_DEBUGEN/C_HALT or debugger hold");
        Need(!cpus[0].CpuWaitSignal.IsSet && !cpus[0].IsHalted, "An independent CPU wait/halt source replaced debugger hold");
        Need(!cpus[0].TimeHandle.Enabled, "Debugger-held reset left an enabled time handle without an executing PE");
        Need(Reg(cpus[0], 15) == 0x20000200 && Reg(cpus[0], 13) == 0x20003f00,
            "Held reset did not initialize the precise reset vector and SP");
        Need(Reg(cpus[0], 0) == 0 && Reg(cpus[0], 5) == 0, "A reset instruction retired before vector catch");
        ulong held = cpus[0].ExecutedInstructions, targetPeer = cpus[1].ExecutedInstructions, externalPeer = peer.ExecutedInstructions;
        ulong time = emulation.MasterTimeSource.ElapsedVirtualTime.Ticks;
        advance(); advance();
        Need(emulation.MasterTimeSource.ElapsedVirtualTime.Ticks > time, "Master virtual time did not advance while debugger held reset core");
        Need(cpus[1].ExecutedInstructions > targetPeer && peer.ExecutedInstructions > externalPeer,
            "Target sibling or separate native machine stopped progressing during debugger-held reset");
        Need(cpus[0].ExecutedInstructions == held && held == 0 && Reg(cpus[0], 0) == 0 && Reg(cpus[0], 5) == 0
            && Reg(cpus[0], 15) == 0x20000200 && cpus[0].HaltedByDebugger && (dhcsr() & 0x20000) != 0,
            "Debugger-held reset PE executed or lost its precise halt");
        Log("MASTER_AND_BOTH_NATIVE_PEERS_PROGRESS_WITH_ZERO_HELD_PE_RETIREMENT masterTicks=" + time
            + "->" + emulation.MasterTimeSource.ElapsedVirtualTime.Ticks
            + " targetSibling=" + targetPeer + "->" + cpus[1].ExecutedInstructions
            + " externalMachine=" + externalPeer + "->" + peer.ExecutedInstructions
            + " heldRetired=" + cpus[0].ExecutedInstructions + " heldPC=0x" + Reg(cpus[0], 15).ToString("x")
            + " heldHandleEnabled=" + cpus[0].TimeHandle.Enabled + " DHCSR=0x" + dhcsr().ToString("x"));
        target.SystemBus.WriteDoubleWord(0xe000edf0, 0xa05f0001, cpus[0]);
        Need(SpinWait.SpinUntil(() => !cpus[0].HaltedByDebugger && (dhcsr() & 0x20000) == 0, 3000), "C_HALT release did not acknowledge");
        advance();
        Need(Reg(cpus[0], 5) == 0x5a && Reg(cpus[0], 0) > 0 && cpus[0].ExecutedInstructions > 0,
            "Debugger release did not execute real instructions from the reset vector");
        Log("DEBUG_RELEASE_RETIRED_RESET_VECTOR_MARKER");
    }
}
