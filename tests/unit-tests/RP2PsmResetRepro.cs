// Standalone bounded native PSM regression. Run against a matching runtime with
// an isolated HOME. Modes: hold, pulse, reset_pending, generation, reassert,
// native_store, foreign_hold; append _2350 for Cortex-M33/RP2350 register layout.
using System;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;
using Antmicro.Renode.Peripherals.GPIOPort;
using Antmicro.Renode.Peripherals.IRQControllers;
using Antmicro.Renode.Peripherals.Memory;
using Antmicro.Renode.Peripherals.Miscellaneous;
using Antmicro.Renode.Time;

public static class RP2PsmResetRepro
{
    static void Need(bool value, string reason) { if(!value) throw new Exception(reason); }
    static void Log(string value) { Console.WriteLine(DateTime.UtcNow.ToString("O") + " " + value); Console.Out.Flush(); }
    static uint Reg(CortexM cpu, int reg) => (uint)cpu.GetRegister(reg);
    public static int Main(string[] args)
    {
        try { Run(args[0]); Log("PASS " + args[0]); Environment.Exit(0); return 0; }
        catch(Exception error) { Log("FAIL " + error); Environment.Exit(1); return 1; }
    }
    sealed class ObservedCortexM : CortexM
    {
        public ObservedCortexM(string model, Machine machine, NVIC nvic, uint index, bool trustZone)
            : base(model, machine, nvic, cpuId: index, enableTrustZone: trustZone) { }
        public override void Reset() { base.Reset(); Interlocked.Increment(ref ResetCount); }
        public int ResetCount;
    }
    sealed class RescuePort : RP2350_DebugPort
    {
        public RescuePort(Machine machine, CortexM core0, CortexM core1) : base(machine, core0, core1) { }
        public void SetRescue(bool value)
        {
            CompleteWrite(false, 8, 0x80000);
            uint unused;
            Need((int)BeginTransfer(true, false, 0, out unused) == 1, "RP-AP request failed");
            CompleteWrite(true, 0, value ? 0x80000000u : 0);
        }
    }
    static void Run(string mode)
    {
        bool rp2350 = mode.EndsWith("_2350");
        mode = mode.Replace("_2350", "");
        var emulation = EmulationManager.Instance.CurrentEmulation;
        emulation.MasterTimeSource.Quantum = TimeInterval.FromMicroseconds(10);
        var machine = new Machine(createLocalTimeSource: true);
        machine.LocalTimeSource.Quantum = TimeInterval.FromMicroseconds(10);
        emulation.AddMachine(machine, "native_psm_reset");
        var bus = machine.SystemBus;
        var clockMode = bus.GetType().GetProperty("SynchronizePeripheralAccessesWithClock");
        if(mode == "clock_join") Need(clockMode != null, "Clock join regression requires the opt-in clock-before-bus prototype");
        clockMode?.SetValue(bus, true);
        Log("CLOCK_BEFORE_BUS_ENABLED " + (clockMode != null));
        var memory = new MappedMemory(machine, 0x4000);
        bus.Register(memory, new BusPointRegistration(0x20000000));
        var gpio = new RP2_GPIOBank0(machine);
        var pio = new RP2040_PIO(machine, gpio, frequency: 125000000);
        bus.Register(pio, new BusRangeRegistration(0x50200000, 0x4000));
        memory.WriteDoubleWord(0, 0x20003ff0);
        memory.WriteDoubleWord(4, 0x20000101);
        // Both real PEs repeatedly execute a PIO MMIO read and increment R0.
        ushort[] initial = { 0x4902, 0x680a, 0x3001, 0xe7fc, 0xbf00, 0xbf00 };
        for(int i = 0; i < initial.Length; i++) memory.WriteWord(0x100 + 2*i, initial[i]);
        memory.WriteDoubleWord(0x10c, 0x50200004);
        // Only a real reset can reach this vector, set R5 and clear old R0.
        ushort[] boot = { 0x255a, 0x4902, 0x680a, 0x3001, 0xe7fc, 0xbf00 };
        for(int i = 0; i < boot.Length; i++) memory.WriteWord(0x200 + 2*i, boot[i]);
        memory.WriteDoubleWord(0x20c, 0x50200004);
        var cpus = new CortexM[2]; var nvics = new NVIC[2];
        for(int i = 0; i < 2; i++)
        {
            nvics[i] = new NVIC(machine);
            cpus[i] = new ObservedCortexM(rp2350 ? "cortex-m33-rp2350" : "cortex-m0+", machine, nvics[i], (uint)i, rp2350);
            bus.Register(cpus[i], new CPURegistrationPoint(i)); machine.SetLocalName(cpus[i], "cpu" + i);
            bus.Register(nvics[i], new BusPointRegistration(0xe000e000, cpu: cpus[i]));
            cpus[i].PerformanceInMips = 100; cpus[i].InitVectorTableOffset = 0x20000000; cpus[i].Reset();
        }
        Antmicro.Renode.Peripherals.RP2APBPeripheral psm = rp2350
            ? (Antmicro.Renode.Peripherals.RP2APBPeripheral)new RP2350_PSM(machine, cpus[0], cpus[1], nvics[0], nvics[1])
            : new RP2040_PSM(machine, cpus[0], cpus[1], nvics[0], nvics[1]);
        uint address = rp2350 ? 0x40018000u : 0x40010000u;
        uint both = 3u << (rp2350 ? 23 : 15), peer = both & (both << 1);
        bus.Register(psm, new BusRangeRegistration(address, 0x4000));
        RP2350_POWMAN powman = null; RescuePort port = null;
        if(mode == "warm_held" || mode == "rescue_held")
        {
            Need(rp2350, "POWMAN test requires RP2350");
            port = new RescuePort(machine, cpus[0], cpus[1]);
            bus.Register(port, NullRegistrationPoint.Instance);
            powman = new RP2350_POWMAN(machine, cpus[0], cpus[1], nvics[0], nvics[1], port);
            bus.Register(powman, new BusRangeRegistration(0x40100000, 0x4000));
            nvics[0].SystemResetRequest.Connect(powman, 0); nvics[1].SystemResetRequest.Connect(powman, 1);
        }
        machine.PostCreationActions();
        Action advance = () => emulation.RunFor(TimeInterval.FromMicroseconds(100));
        Action<uint> assert = mask => bus.WriteDoubleWord(address + 0x2004, mask);
        Action<uint> release = mask => bus.WriteDoubleWord(address + 0x3004, mask);
        Func<uint> off = () => bus.ReadDoubleWord(address + 4);
        Func<uint> done = () => bus.ReadDoubleWord(address + 0xc);
        advance();
        foreach(var cpu in cpus) Need(Reg(cpu, 0) > 100 && Reg(cpu, 5) == 0, "Initial native PIO loop did not run");
        Log("BOTH_NATIVE_PIO_LOOPS_RUNNING " + Reg(cpus[0], 0) + " " + Reg(cpus[1], 0));
        memory.WriteDoubleWord(4, 0x20000201);
        if(mode == "clock_join")
        {
            emulation.StartAll();
            ulong active = cpus[1].ExecutedInstructions;
            Need(SpinWait.SpinUntil(() => cpus[1].ExecutedInstructions > active + 1000, 3000), "Peer stopped polling real PIO");
            var write = Task.Run(() => machine.ClockSource.ExecuteInLock(() =>
            {
                Log("CLOCK_OWNED_BEFORE_PSM_NATIVE_PEER_POLLING");
                Thread.Sleep(20);
                assert(peer);
                Need((off() & peer) == 0, "Pending request acknowledged while native peer waits for clock");
                Need((done() & peer) == 0, "Pending request reported ready under clock");
            }));
            Need(write.Wait(3000), "PSM MMIO reset joined native peer while owning clock");
            Log("CLOCK_OWNED_PSM_TRANSACTION_RETURNED");
            Need(SpinWait.SpinUntil(() => (off() & peer) != 0, 3000), "Deferred native reset never acknowledged");
            emulation.PauseAll();
            ulong held = cpus[1].ExecutedInstructions;
            Need(Reg(cpus[1], 0) == 0, "Reset acknowledgement preceded native register reset");
            advance(); advance();
            Need(cpus[1].ExecutedInstructions == held && Reg(cpus[1], 0) == 0, "Clock-joined PE retired while held");
            release(peer); advance();
            Need(Reg(cpus[1], 5) == 0x5a && Reg(cpus[1], 0) > 0, "Clock-joined peer did not boot reset vector on release");
            return;
        }
        if(mode == "native_store")
        {
            // CPU0 writes FORCE_OFF_SET, polls actual reset acknowledgement,
            // then clears it: the same ordering as pico_multicore's barrier.
            ushort[] writer = { 0x4906, 0x4807, 0x6008, 0x4907, 0x680a, 0x4202, 0xd0fc, 0x4906, 0x6008, 0x25a5, 0xe7fe, 0xbf00, 0xbf00, 0xbf00 };
            for(int i = 0; i < writer.Length; i++) memory.WriteWord(0x300 + 2*i, writer[i]);
            memory.WriteDoubleWord(0x31c, address + 0x2004);
            memory.WriteDoubleWord(0x320, peer);
            memory.WriteDoubleWord(0x324, address + 4);
            memory.WriteDoubleWord(0x328, address + 0x3004);
            cpus[0].SetRegister(15, 0x20000300);
            advance(); advance();
            Need(Reg(cpus[0], 5) == 0xa5, "Native reset-confirmation polling/store sequence failed");
            Need(Reg(cpus[1], 5) == 0x5a && Reg(cpus[1], 0) > 0, "Peer did not reset and restart after native release");
            return;
        }
        if(mode == "generation")
        {
            var monitor = typeof(CortexM).GetField("reset", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(cpus[1]);
            var hold = typeof(CortexM).GetField("powerSequencerResetHeld", BindingFlags.Instance | BindingFlags.NonPublic);
            Task running;
            lock(monitor)
            {
                assert(peer);
                running = Task.Run(advance);
                Need(SpinWait.SpinUntil(() => (bool)hold.GetValue(cpus[1]), 3000), "Worker did not reach reset-dispatch barrier");
                Need((off() & peer) == 0, "FRCE_OFF acknowledged before CPU reset finished");
                Need((done() & peer) == 0, "DONE claimed a pending reset was ready");
                psm.Reset();
                assert(peer); release(peer); assert(peer);
                Log("GENERATION_CHANGED_WITH_NATIVE_RESET_DISPATCH_BLOCKED");
            }
            Need(running.Wait(3000), "Reset generation/reassert callback did not finish");
            Need((off() & peer) != 0, "Latest reassertion was lost");
            Need(Reg(cpus[1], 0) == 0, "Acknowledged reset did not reset native registers");
            release(peer); advance();
            Need(Reg(cpus[1], 5) == 0x5a && Reg(cpus[1], 0) > 0, "Latest release did not boot reset vector");
            return;
        }
        int[] beforeResets = { ((ObservedCortexM)cpus[0]).ResetCount, ((ObservedCortexM)cpus[1]).ResetCount };
        if(mode == "pulse" || mode == "double_pulse")
        {
            assert(both); release(both);
            if(mode == "double_pulse") { assert(both); release(both); }
        }
        else if(mode == "reset_pending") { assert(both); psm.Reset(); }
        else assert(both);
        Need((off() & both) == 0, "FRCE_OFF acknowledged before deferred reset");
        if(mode != "reset_pending") Need((done() & both) == 0, "DONE claimed pending reset ready");
        advance();
        if(mode == "pulse" || mode == "double_pulse")
        {
            foreach(var cpu in cpus) Need(Reg(cpu, 5) == 0x5a && Reg(cpu, 0) > 0, "Short assert-clear reset pulse was lost");
            for(int i = 0; i < 2; i++) Need(((ObservedCortexM)cpus[i]).ResetCount - beforeResets[i] == (mode == "double_pulse" ? 2 : 1), "Accepted reset assertion edge was lost");
            Need((off() & both) == 0 && (done() & both) == both, "Pulse did not complete release");
            return;
        }
        if(mode == "reset_pending")
        {
            foreach(var cpu in cpus) Need(Reg(cpu, 5) == 0, "Invalidated pending reset executed after PSM reset");
            Need((off() & both) == 0 && (done() & both) == both, "PSM reset left stale processor hold");
            return;
        }
        Need((off() & both) == both && (done() & both) == 0, "Held state not acknowledged");
        ulong[] stopped = { cpus[0].ExecutedInstructions, cpus[1].ExecutedInstructions };
        foreach(var cpu in cpus) Need(Reg(cpu, 0) == 0, "FRCE_OFF acknowledged before native reset completed");
        advance(); advance();
        for(int i = 0; i < 2; i++) Need(cpus[i].ExecutedInstructions == stopped[i] && Reg(cpus[i], 0) == 0, "Held PE retired instructions");
        if(mode == "peripheral_reset")
        {
            psm.Reset(); advance();
            foreach(var cpu in cpus) Need(Reg(cpu, 5) == 0x5a && Reg(cpu, 0) > 0, "PSM reset did not reconcile previously applied hold");
            Need((off() & both) == 0 && (done() & both) == both, "PSM reset retained stale status");
            return;
        }
        if(mode == "release_barrier")
        {
            var pause = typeof(CPUCore).GetField("pauseLock", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(cpus[1]);
            var hold = typeof(CortexM).GetField("powerSequencerResetHeld", BindingFlags.Instance | BindingFlags.NonPublic);
            emulation.StartAll();
            lock(pause)
            {
                release(peer);
                Need(SpinWait.SpinUntil(() => !(bool)hold.GetValue(cpus[1]), 3000), "Release did not reach lifecycle boundary");
                Need((off() & peer) == 0, "FRCE_OFF held acknowledgement survived release dispatch");
                Need((done() & peer) == 0, "DONE acknowledged release before lifecycle completion");
                Need(cpus[1].ExecutedInstructions == stopped[1], "PE ran while lifecycle release was blocked");
                Log("RELEASE_ACK_WITHDRAWN_BEFORE_NATIVE_RESUME");
            }
            Need(SpinWait.SpinUntil(() => cpus[1].ExecutedInstructions > stopped[1], 3000), "Lifecycle release did not resume native execution");
            emulation.PauseAll();
        }
        if(mode == "warm_held" || mode == "watchdog_held")
        {
            int count = ((ObservedCortexM)cpus[1]).ResetCount;
            if(mode == "warm_held") bus.WriteDoubleWord(0xe000ed0c, 0x05fa0004, cpus[1]);
            else
            {
                Need(rp2350, "Selective watchdog test requires RP2350");
                bus.WriteDoubleWord(address + 8, peer);
                machine.ClockSource.ExecuteInLock(() => ((RP2350_PSM)psm).ResetFromWatchdog(null));
            }
            advance(); advance();
            Need(((ObservedCortexM)cpus[1]).ResetCount == count + 1, "Held PE did not receive the requested reset");
            Need((off() & peer) != 0 && (done() & peer) == 0, "Secondary reset changed PSM hold status");
            Need(cpus[1].ExecutedInstructions == stopped[1], "Secondary reset released the PSM-held PE");
        }
        if(mode == "rescue_held")
        {
            port.SetRescue(true); advance(); advance();
            foreach(var cpu in cpus) Need(cpu.CpuWaitSignal.IsSet, "Rescue did not hold both real PEs");
            assert(peer); advance();
            ulong heldInstructions = cpus[1].ExecutedInstructions;
            machine.ClockSource.ExecuteInLock(() => port.SetRescue(false));
            advance(); advance();
            Need((off() & peer) != 0 && cpus[1].ExecutedInstructions == heldInstructions, "Rescue release removed independent PSM hold");
            Need(Reg(cpus[0], 5) == 0x5a && Reg(cpus[0], 0) > 0, "Rescue release failed to boot free core0");
            release(peer); advance();
            Need(Reg(cpus[1], 5) == 0x5a && Reg(cpus[1], 0) > 0, "PSM release failed after rescue release");
            return;
        }
        if(mode == "reassert") { release(both); assert(both); advance(); Need((off() & both) == both, "Reassertion lost"); }
        if(mode == "foreign_hold")
        {
            cpus[1].CpuWaitSignal.Set(); cpus[1].Reset();
            release(both); advance(); advance();
            Need(cpus[1].CpuWaitSignal.IsSet && Reg(cpus[1], 0) == 0, "PSM release cleared independent CPU wait hold");
            cpus[1].CpuWaitSignal.Unset(); cpus[1].IsHalted = false; cpus[1].Resume(); advance();
            Need(Reg(cpus[1], 5) == 0x5a && Reg(cpus[1], 0) > 0, "Foreign hold release did not boot vector");
            return;
        }
        release(peer); advance();
        Need(Reg(cpus[0], 0) == 0 && cpus[0].ExecutedInstructions == stopped[0], "Releasing peer also released core0");
        Need(Reg(cpus[1], 5) == 0x5a && Reg(cpus[1], 0) > 0, "Peer release did not boot reset vector");
        release(both); advance();
        Need(Reg(cpus[0], 5) == 0x5a && Reg(cpus[0], 0) > 0, "Core0 release did not boot reset vector");
        Need((done() & both) == both, "DONE did not acknowledge released domains");
    }
}
