// Standalone native debug-entry regression. Compile against the matching
// runtime DLLs and platform-lib; run with isolated HOME and a process timeout.
// Modes: wfe, wfi, wfe_deep, wfi_deep, event_set, exclusive, lockup, live_wfe, live_wfi.
using System;
using System.Threading;
using System.Threading.Tasks;
using System.Reflection;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;
using Antmicro.Renode.Peripherals.IRQControllers;
using Antmicro.Renode.Peripherals.Memory;
using Antmicro.Renode.Time;

public static class CortexMDebugSleepRepro
{
    static void Need(bool value, string reason) { if(!value) throw new Exception(reason); }
    static void Log(string s) { Console.WriteLine(DateTime.UtcNow.ToString("O") + " " + s); Console.Out.Flush(); }
    public static int Main(string[] args)
    {
        try { Run(args.Length == 0 ? "wfe" : args[0]); Environment.Exit(0); return 0; }
        catch(Exception e) { Log("HARNESS_FAILURE " + e); Environment.Exit(1); return 1; }
    }
    static void Run(string mode)
    {
        var live = mode.StartsWith("live_");
        var description = mode;
        if(live) mode = mode.Substring(5);
        var emulation = EmulationManager.Instance.CurrentEmulation;
        emulation.MasterTimeSource.Quantum = TimeInterval.FromMicroseconds(1);
        var machine = new Machine(createLocalTimeSource: true);
        machine.LocalTimeSource.Quantum = TimeInterval.FromMicroseconds(1);
        emulation.AddMachine(machine, "debug_sleep_native");
        var nvic = new NVIC(machine);
        var cpu = new CortexM("cortex-m33-rp2350", machine, nvic, enableTrustZone: true);
        machine.SystemBus.Register(cpu, new CPURegistrationPoint(0));
        machine.SetLocalName(cpu, "cpu");
        machine.SystemBus.Register(nvic, new BusPointRegistration(0xe000e000, cpu: cpu));
        var ram = new MappedMemory(machine, 0x4000);
        machine.SystemBus.Register(ram, new BusPointRegistration(0x20000000));
        ram.WriteDoubleWord(0, 0x20003000);
        ram.WriteDoubleWord(4, mode == "lockup" ? 0x20000100u : 0x20000101u);
        ushort wait = mode.StartsWith("wfi") ? (ushort)0xbf30 : (ushort)0xbf20;
        ram.WriteWord(0x100, wait);
        ram.WriteWord(0x102, 0x212a); // movs r1, #42
        ram.WriteWord(0x104, wait);
        ram.WriteWord(0x106, 0x223b); // movs r2, #59
        ram.WriteWord(0x108, wait);
        ram.WriteWord(0x10a, 0x2444); // movs r4, #0x44
        ram.WriteWord(0x10c, 0x3301); // adds r3, #1
        ram.WriteWord(0x10e, 0xe7fd); // b 0x2000010c
        if(mode == "exclusive")
        {
            ram.WriteDoubleWord(0x100, 0x0f00e853); // ldrex r0, [r3]
            ram.WriteWord(0x104, 0xbf20); // wfe
            ram.WriteDoubleWord(0x106, 0x2100e843); // strex r1, r2, [r3]
            ram.WriteWord(0x10a, 0xe7fe);
            ram.WriteDoubleWord(0x1000, 0x11223344);
        }
        if(mode == "lockup") machine.SystemBus.Register(new FaultingVectors(), new BusPointRegistration(0x30000000));
        cpu.InitVectorTableOffset = mode == "lockup" ? 0x30000000u : 0x20000000u;
        cpu.Reset();
        if(mode == "exclusive") { cpu.SetRegister(3, 0x20001000); cpu.SetRegister(2, 0x55667788); }
        cpu.EnableMemoryMappedDebug = true;
        nvic.WriteDoubleWord(0xdf0, 0xa05f0001);
        if(mode.EndsWith("_deep")) nvic.WriteDoubleWord(0xd10, 4);
        var enters = 0;
        var exits = 0;
        uint sleepPC = 0, sleepR1 = 0, sleepR2 = 0;
        var firstSleep = new ManualResetEventSlim();
        var secondSleep = new ManualResetEventSlim();
        var loopReached = new ManualResetEventSlim();
        var resetMonitor = typeof(CortexM).GetField("reset", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(cpu);
        cpu.AddHookAtWfiStateChange(entered =>
        {
            if(entered)
            {
                // This notification runs on the executing native CPU thread.
                Volatile.Write(ref sleepPC, (uint)cpu.PC);
                Volatile.Write(ref sleepR1, (uint)cpu.GetRegister(1));
                Volatile.Write(ref sleepR2, (uint)cpu.GetRegister(2));
                if(Interlocked.Increment(ref enters) == 1) firstSleep.Set();
                else secondSleep.Set();
            }
            else
            {
                Interlocked.Increment(ref exits);
                Need(Task.Run(() => { lock(resetMonitor) { } }).Wait(TimeSpan.FromSeconds(3)),
                    "Sleep-exit callback owns the CPU reset monitor");
            }
        });
        if(live) cpu.SetHookAtBlockBegin((address, size) =>
        {
            if(address == 0x2000010c && (uint)cpu.GetRegister(3) > 0) loopReached.Set();
        });
        var advances = 0;
        Action advance = () =>
        {
            if(!live) { emulation.RunFor(TimeInterval.FromMicroseconds(100)); return; }
            switch(++advances)
            {
            case 1:
                emulation.StartAll();
                Need(firstSleep.Wait(TimeSpan.FromSeconds(5)), "Live native core did not reach first wait");
                break;
            case 2:
                Need(secondSleep.Wait(TimeSpan.FromSeconds(5)), "Live native resume did not reach next wait");
                break;
            default:
                Need(loopReached.Wait(TimeSpan.FromSeconds(5)), "Live native PC rewrite never reached ADD loop");
                nvic.WriteDoubleWord(0xdf0, 0xa05f0003);
                Need(SpinWait.SpinUntil(() => (nvic.ReadDoubleWord(0xdf0) & 0x20000) != 0,
                    TimeSpan.FromSeconds(5)), "Live final native halt failed");
                break;
            }
        };
        advance();
        if(mode == "exclusive")
        {
            Need((uint)cpu.PC == 0x20000106 && (uint)cpu.GetRegister(0) == 0x11223344, "Real LDREX/WFE did not complete");
            nvic.WriteDoubleWord(0xdf0, 0xa05f0003);
            Need(SpinWait.SpinUntil(() => (nvic.ReadDoubleWord(0xdf0) & 0x30000) == 0x30000,
                TimeSpan.FromSeconds(5)), "Exclusive-test halt failed");
            Need((nvic.ReadDoubleWord(0xdf0) & 0x40000) == 0, "Exclusive test did not wake");
            nvic.WriteDoubleWord(0xdf0, 0xa05f0001);
            WaitRunning(nvic);
            advance();
            Need((uint)cpu.GetRegister(1) == 1 && ram.ReadDoubleWord(0x1000) == 0x11223344,
                "Asynchronous debug wake did not clear the real exclusive reservation");
            Log("NATIVE_DEBUG_WAKE_CANCELLED_LDREX_RESERVATION");
            return;
        }
        if(mode != "lockup")
        {
            Need((live ? Volatile.Read(ref sleepPC) : (uint)cpu.PC) == 0x20000102
                && (live ? Volatile.Read(ref sleepR1) : (uint)cpu.GetRegister(1)) == 0,
                "Real wait instruction did not sleep at its next PC");
            Need((nvic.ReadDoubleWord(0xdf0) & 0x40000) != 0, "DHCSR did not report actual sleep");
            Need(mode.EndsWith("_deep") ? nvic.InDeepSleep.IsSet : nvic.InSleep.IsSet, "Sleep output was not asserted");
            Need(enters == 1 && exits == 0, "Unexpected sleep transition before debug");
            if(mode == "event_set") cpu.SetEventFlag();
        }
        else Need(nvic.Lockup.IsSet && (uint)cpu.PC == 0xeffffffe, "Fixture did not cause real reset Lockup: PC=" + cpu.PC + " signal=" + nvic.Lockup.IsSet);
        Log("NATIVE_WAIT_OR_LOCKUP_BEFORE_DEBUG mode=" + description + " pc="
            + (live ? Volatile.Read(ref sleepPC).ToString("x") : cpu.PC.ToString()));
        nvic.WriteDoubleWord(0xdf0, 0xa05f0003);
        Need(SpinWait.SpinUntil(() => (nvic.ReadDoubleWord(0xdf0) & 0x30000) == 0x30000,
            TimeSpan.FromSeconds(5)), "Native halt was not acknowledged");
        var halted = nvic.ReadDoubleWord(0xdf0);
        Need((halted & 0xc0000) == 0, "Acknowledged Debug state still reports sleep or Lockup");
        Need(!nvic.InSleep.IsSet && !nvic.InDeepSleep.IsSet && !nvic.Lockup.IsSet, "Actual sleep/Lockup outputs remained asserted");
        if(mode == "lockup") Need((uint)cpu.PC == 0xeffffffe, "Debug entry changed Lockup return address");
        if(mode != "lockup")
        {
            Need((uint)cpu.PC == 0x20000102 && (uint)cpu.GetRegister(1) == 0, "Debug entry retired the instruction after the wait");
            Need(exits == 1, "Debug entry did not publish exactly one native sleep exit");
            nvic.WriteDoubleWord(0xdf0, 0xa05f0001);
            WaitRunning(nvic);
            advance();
            Need((live ? Volatile.Read(ref sleepR1) : (uint)cpu.GetRegister(1)) == 42,
                "Resume remained blocked in native wait state");
            var secondPC = mode == "event_set" ? 0x2000010au : 0x20000106u;
            Need((live ? Volatile.Read(ref sleepPC) : (uint)cpu.PC) == secondPC
                && (live ? Volatile.Read(ref sleepR2) : (uint)cpu.GetRegister(2)) == (mode == "event_set" ? 59u : 0u),
                "Debug entry changed Event Register semantics at the next wait");
            Need((nvic.ReadDoubleWord(0xdf0) & 0x40000) != 0 && enters == 2 && exits == 1,
                "Second wait did not assert sleep once, or resume replayed sleep-exit notification");
            nvic.WriteDoubleWord(0xdf0, 0xa05f0003);
            Need(SpinWait.SpinUntil(() => (nvic.ReadDoubleWord(0xdf0) & 0x30000) == 0x30000,
                TimeSpan.FromSeconds(5)), "Second halt failed");
        }
        // Use the real asynchronous DCRDR/DCRSR path to change PC while halted.
        nvic.WriteDoubleWord(0xdf8, 0x2000010c);
        nvic.WriteDoubleWord(0xdf4, 0x1000f);
        Need(SpinWait.SpinUntil(() => (nvic.ReadDoubleWord(0xdf0) & 0x10000) != 0,
            TimeSpan.FromSeconds(5)), "PC transfer did not complete");
        if(mode == "lockup")
        {
            nvic.WriteDoubleWord(0xdf8, (uint)cpu.GetRegister((int)CortexMRegisters.CPSR) | 0x01000000u);
            nvic.WriteDoubleWord(0xdf4, 0x10010);
            Need(SpinWait.SpinUntil(() => (nvic.ReadDoubleWord(0xdf0) & 0x10000) != 0,
                TimeSpan.FromSeconds(5)), "EPSR transfer failed");
        }
        nvic.WriteDoubleWord(0xdf0, 0xa05f0001);
        WaitRunning(nvic);
        advance();
        Need((uint)cpu.GetRegister(3) > 0 && !nvic.Lockup.IsSet, "Debugger PC rewrite could not resume: PC=" + cpu.PC + " r3=" + cpu.GetRegister(3) + " lockup=" + nvic.Lockup.IsSet);
        Log("NATIVE_DEBUG_WAKE_RESUME_AND_PC_REWRITE_PASSED mode=" + description + " r3=" + cpu.GetRegister(3));
    }
    sealed class FaultingVectors : IDoubleWordPeripheral, IKnownSize
    {
        public uint ReadDoubleWord(long offset) => throw new BusAccessException(BusAccessError.GenericError);
        public void WriteDoubleWord(long offset, uint value) { }
        public void Reset() { }
        public long Size => 0x1000;
    }
    static void WaitRunning(NVIC nvic)
    {
        Need(SpinWait.SpinUntil(() => (nvic.ReadDoubleWord(0xdf0) & 0x20000) == 0,
            TimeSpan.FromSeconds(5)), "Resume was not applied");
    }
}
