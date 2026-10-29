// Standalone bounded native concurrency regression. Compile as a net8.0
// executable referencing the matching Renode runtime DLLs, and copy its
// platform-lib directory beside this executable. Run with isolated HOME.
// Modes: bus, direct, bkpt, fpb, step. Each mode owns its process; a detected
// bus-lock deadlock exits 42, and every success checks actual DHCSR stop and
// native register state before exiting. The outer test runner must bound it.
// The bus barrier proves a real MEM-AP write owns NVIC's SystemBus lock while
// a real native LDR is waiting for it. The hit barriers stop inside a real
// PPB load after dispatch, so Pause's native exit request cannot skip the
// following debug event at the start of a translated block.
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;
using Antmicro.Renode.Peripherals.IRQControllers;
using Antmicro.Renode.Peripherals.Memory;
using Antmicro.Renode.Time;

public static class CortexMDebugConcurrencyRepro
{
    static void Log(string s) { Console.WriteLine(DateTime.UtcNow.ToString("O") + " " + s); Console.Out.Flush(); }
    static void Need(bool value, string reason) { if(!value) throw new Exception(reason); }
    public static int Main(string[] args)
    {
        try
        {
            if(args.Length != 0 && (args[0] == "bkpt" || args[0] == "fpb" || args[0] == "step")) RunNativeHitAgainstPause(args[0]);
            else Run(args.Length != 0 && args[0] == "direct");
            return 0;
        }
        catch(Exception e) { Log("HARNESS_FAILURE " + e); Environment.Exit(1); return 1; }
    }
    static void Run(bool direct)
    {
        var emulation = EmulationManager.Instance.CurrentEmulation;
        emulation.MasterTimeSource.Quantum = TimeInterval.FromSeconds(1);
        var machine = new Machine(createLocalTimeSource: true);
        machine.LocalTimeSource.Quantum = TimeInterval.FromSeconds(1);
        emulation.AddMachine(machine, "ppb_halt_audit");
        var nvic = new NVIC(machine);
        var cpu = new CortexM("cortex-m33-rp2350", machine, nvic, enableTrustZone: true);
        machine.SystemBus.Register(cpu, new CPURegistrationPoint(0));
        machine.SetLocalName(cpu, "cpu");
        machine.SystemBus.Register(nvic, new BusPointRegistration(0xe000e000, cpu: cpu));
        var ram = new MappedMemory(machine, 0x4000);
        machine.SystemBus.Register(ram, new BusPointRegistration(0x20000000));
        ram.WriteDoubleWord(0, 0x20003000);
        ram.WriteDoubleWord(4, 0x20000101);
        ram.WriteWord(0x100, 0x4901); // ldr r1, [pc, #4]
        ram.WriteWord(0x102, 0x6808); // ldr r0, [r1] -- actual NVIC CPUID access
        ram.WriteWord(0x104, 0xe7fd); // b 0x20000102
        ram.WriteDoubleWord(0x108, 0xe000ed00);
        cpu.InitVectorTableOffset = 0x20000000;
        cpu.Reset();
        cpu.EnableMemoryMappedDebug = true;
        nvic.WriteDoubleWord(0xdf0, 0xa05f0001);
        var port = new Port(machine, cpu);
        port.Power();
        port.WriteAP(0x2d00, 0x0b800052);
        port.WriteAP(0x2d04, 0xe000edf0);
        var entered = new ManualResetEventSlim();
        var release = new ManualResetEventSlim();
        var returned = new ManualResetEventSlim();
        Thread cpuThread = null;
        var reads = 0;
        machine.SystemBus.SetHookAfterPeripheralRead<uint>(nvic, (value, offset) => { if(offset == 0xd00) Interlocked.Increment(ref reads); return value; });
        cpu.SetHookAtBlockBegin((address, size) =>
        {
            if(address != 0x20000100 || entered.IsSet) return;
            cpuThread = Thread.CurrentThread;
            Log("NATIVE_CPU_REACHED_LDR_BLOCK thread=" + cpuThread.ManagedThreadId);
            entered.Set();
            Need(release.Wait(TimeSpan.FromSeconds(10)), "CPU release barrier timeout");
            returned.Set();
        });
        var locks = (Dictionary<int, object>)typeof(SystemBus).GetField("peripheralAccessLocks", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(machine.SystemBus);
        var busLock = locks[nvic.GetHashCode()];
        if(!direct)
        {
            machine.SystemBus.SetHookBeforePeripheralWrite<uint>(nvic, (value, offset) =>
            {
                if(offset != 0xdf0) return value;
                Need(Monitor.IsEntered(busLock), "MEM-AP write did not hold the real NVIC bus access lock");
                Log("MEMAP_DHCSR_WRITE_OWNS_NVIC_BUS_LOCK");
                release.Set();
                Need(returned.Wait(TimeSpan.FromSeconds(5)), "CPU block hook did not return");
                Need(SpinWait.SpinUntil(() => (cpuThread.ThreadState & ThreadState.WaitSleepJoin) != 0, TimeSpan.FromSeconds(5)), "CPU did not block on its PPB read");
                Need(Volatile.Read(ref reads) == 0, "CPU unexpectedly completed its PPB read before halt");
                Log("CPU_WAITING_AFTER_NATIVE_LDR_DISPATCH reads=" + reads + " threadState=" + cpuThread.ThreadState);
                return value; // invoke the production NVIC DHCSR implementation
            });
        }
        emulation.StartAll();
        Need(entered.Wait(TimeSpan.FromSeconds(10)), "Native CPU did not start");
        Task halt;
        if(direct)
        {
            release.Set();
            Need(SpinWait.SpinUntil(() => Volatile.Read(ref reads) > 0, TimeSpan.FromSeconds(5)), "Positive control CPU did not poll NVIC");
            Log("DIRECT_CONTROL_CPU_POLLING reads=" + reads);
            halt = Task.Run(() => nvic.WriteDoubleWord(0xdf0, 0xa05f0003));
        }
        else halt = Task.Run(() => port.WriteAP(0x2d0c, 0xa05f0003));
        if(!halt.Wait(TimeSpan.FromSeconds(3)))
        {
            Log("HALT_DEADLOCK_REPRODUCED task=" + halt.Status + " cpuThread=" + cpuThread.ThreadState
                + " reads=" + reads + " debuggerFlag=" + cpu.HaltedByDebugger + " busLockUnavailable=" + !Monitor.TryEnter(busLock));
            Environment.Exit(42); // bound the intentionally deadlocked native process
        }
        Log("HALT_COMPLETED direct=" + direct + " reads=" + reads + " debuggerFlag=" + cpu.HaltedByDebugger);
        Need(SpinWait.SpinUntil(() => (nvic.ReadDoubleWord(0xdf0) & 0x30000) == 0x30000, TimeSpan.FromSeconds(5)), "Halt was not acknowledged after the CPU stopped");
        Need(Volatile.Read(ref reads) > 0, "CPU never completed its real PPB read");
        var stoppedReads = Volatile.Read(ref reads);
        Thread.Sleep(20);
        Need(stoppedReads == Volatile.Read(ref reads), "S_HALT acknowledged an executing CPU");
        nvic.WriteDoubleWord(0xdf4, 15);
        Need(SpinWait.SpinUntil(() => (nvic.ReadDoubleWord(0xdf0) & 0x10000) != 0, TimeSpan.FromSeconds(5)), "DCRSR did not finish");
        Need(nvic.ReadDoubleWord(0xdf8) == (uint)cpu.PC, "DCRSR read does not match stopped native PC");
        Log("ACKNOWLEDGED_NATIVE_STOP_AND_REGISTER_READ reads=" + stoppedReads + " pc=" + cpu.PC);
        Environment.Exit(0); // each scenario owns its process and all background CPU threads
    }
    static void RunNativeHitAgainstPause(string mode)
    {
        var emulation = EmulationManager.Instance.CurrentEmulation;
        var machine = new Machine(createLocalTimeSource: true);
        emulation.AddMachine(machine, "debug_hit_pause");
        var nvic = new NVIC(machine);
        var cpu = new CortexM("cortex-m33-rp2350", machine, nvic, enableTrustZone: true);
        machine.SystemBus.Register(cpu, new CPURegistrationPoint(0));
        machine.SetLocalName(cpu, "cpu");
        machine.SystemBus.Register(nvic, new BusPointRegistration(0xe000e000, cpu: cpu));
        var ram = new MappedMemory(machine, 0x4000);
        machine.SystemBus.Register(ram, new BusPointRegistration(0x20000000));
        ram.WriteDoubleWord(0, 0x20003000);
        ram.WriteDoubleWord(4, 0x20000101);
        // A real PPB load inside the translated block provides a barrier
        // after native dispatch, before the following BKPT/FPB instruction.
        ram.WriteWord(0x100, 0x680a); // ldr r2, [r1]
        ram.WriteWord(0x102, mode == "bkpt" ? (ushort)0xbe00 : (ushort)0x3001);
        ram.WriteWord(0x104, 0x3101);
        ram.WriteWord(0x106, 0xe7fd);
        cpu.InitVectorTableOffset = 0x20000000;
        cpu.Reset();
        cpu.EnableMemoryMappedDebug = true;
        if(mode == "fpb")
        {
            var fpb = new ARM_FlashPatchBreakpoint(machine, cpu);
            fpb.WriteDoubleWord(8, 0x20000103);
            fpb.WriteDoubleWord(0, 3);
        }
        nvic.WriteDoubleWord(0xdf0, mode == "step" ? 0xa05f0005u : 0xa05f0001u);
        var entered = new ManualResetEventSlim();
        var release = new ManualResetEventSlim();
        cpu.SetRegister(1, 0xe000ed00);
        machine.SystemBus.SetHookAfterPeripheralRead<uint>(nvic, (value, offset) =>
        {
            if(offset != 0xd00 || entered.IsSet) return value;
            entered.Set();
            Need(release.Wait(TimeSpan.FromSeconds(5)), "Native hit release barrier timed out");
            return value;
        });
        emulation.StartAll();
        Need(entered.Wait(TimeSpan.FromSeconds(5)), "Native block did not execute");
        var pauseLock = typeof(BaseCPU).GetField("pauseLock", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(cpu);
        var pause = Task.Run(() => cpu.Pause());
        Need(SpinWait.SpinUntil(() =>
        {
            if(!Monitor.TryEnter(pauseLock)) return true;
            Monitor.Exit(pauseLock);
            return false;
        }, TimeSpan.FromSeconds(5)), "External Pause did not acquire the actual pauseLock");
        Log("EXTERNAL_PAUSE_OWNS_PAUSE_LOCK_BEFORE_NATIVE_" + mode);
        release.Set();
        Need(pause.Wait(TimeSpan.FromSeconds(5)), "Native debug callback deadlocked against Pause");
        Need(SpinWait.SpinUntil(() => (nvic.ReadDoubleWord(0xdf0) & 0x30000) == 0x30000,
            TimeSpan.FromSeconds(5)), "Native hit did not acknowledge actual stop");
        Need(((uint)cpu.PC & ~1u) == (0x20000102u), "Native hit PC is imprecise");
        Need((uint)cpu.GetRegister(0) == (0u), "Native hit retired the wrong instruction count");
        Need(nvic.ReadDoubleWord(0xd30) == (mode == "step" ? 1u : 2u), "Native hit DFSR cause is incorrect");
        Log("NATIVE_HIT_PAUSE_COMPLETED mode=" + mode + " pc=" + cpu.PC + " r0=" + cpu.GetRegister(0));
        Environment.Exit(0);
    }

    sealed class Port : RP2350_DebugPort
    {
        public Port(IMachine m, CortexM c) : base(m, c, null) { }
        public void Power() { CompleteWrite(false, 4, 0x50000000); }
        public void WriteAP(uint address, uint value)
        {
            CompleteWrite(false, 8, address & ~0xfu);
            var a = (byte)(address & 0xc);
            Need((int)BeginTransfer(true, false, a, out var _) == 1, "AP did not acknowledge the write");
            CompleteWrite(true, a, value);
        }
    }
}
