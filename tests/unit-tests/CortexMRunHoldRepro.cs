// Standalone bounded native regression. Build as net8.0 executable against the
// matching runtime DLLs and platform-lib, then run with an isolated HOME.
// Modes: held, pulse, reset_low, release_completion, reassert_completion,
// foreign_hold, foreign_release, debug_hold. The outer runner bounds each process.
using System;
using System.Threading;
using System.Threading.Tasks;
using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;
using Antmicro.Renode.Peripherals.IRQControllers;
using Antmicro.Renode.Peripherals.Memory;
using Antmicro.Renode.Time;

public static class CortexMRunHoldRepro
{
    static void Log(string value) { Console.WriteLine(DateTime.UtcNow.ToString("O") + " " + value); Console.Out.Flush(); }
    static void Need(bool value, string reason) { if(!value) throw new Exception(reason); }
    public static int Main(string[] args)
    {
        try { Run(args.Length == 0 ? "held" : args[0]); Environment.Exit(0); return 0; }
        catch(Exception error) { Log("HARNESS_FAILURE " + error); Environment.Exit(1); return 1; }
    }

    static void Run(string mode)
    {
        var emulation = EmulationManager.Instance.CurrentEmulation;
        emulation.MasterTimeSource.Quantum = TimeInterval.FromMicroseconds(1);
        var machine = new Machine(createLocalTimeSource: true);
        machine.LocalTimeSource.Quantum = TimeInterval.FromMicroseconds(1);
        emulation.AddMachine(machine, "run_hold_native");
        var cpus = new CortexM[2];
        var nvics = new NVIC[2];
        for(var i = 0; i < 2; i++)
        {
            nvics[i] = new NVIC(machine);
            cpus[i] = new CortexM("cortex-m33-rp2350", machine, nvics[i], cpuId: (uint)i, enableTrustZone: true);
            machine.SystemBus.Register(cpus[i], new CPURegistrationPoint(i));
            machine.SetLocalName(cpus[i], "cpu" + i);
            machine.SystemBus.Register(nvics[i], new BusPointRegistration(0xe000e000, cpu: cpus[i]));
        }
        var ram = new MappedMemory(machine, 0x4000);
        machine.SystemBus.Register(ram, new BusPointRegistration(0x20000000));
        ram.WriteDoubleWord(0, 0x20003000);
        ram.WriteDoubleWord(4, 0x20000101);
        ram.WriteWord(0x100, 0x3001); // adds r0, #1
        ram.WriteWord(0x102, 0xe7fd); // b 0x20000100
        // A distinct reset vector proves release boots, rather than resuming
        // an old PC. These instructions are reached only after a real reset.
        ram.WriteWord(0x200, 0x255a); // movs r5, #0x5a
        ram.WriteWord(0x202, 0x3001); // adds r0, #1
        ram.WriteWord(0x204, 0xe7fd); // b 0x20000202
        var port = new RP2350_DebugPort(machine, cpus[0], cpus[1]);
        machine.SystemBus.Register(port, NullRegistrationPoint.Instance);
        machine.SetLocalName(port, "debug_port");
        foreach(var cpu in cpus) { cpu.InitVectorTableOffset = 0x20000000; cpu.Reset(); }
        var resets = 0;
        machine.MachineReset += _ => Interlocked.Increment(ref resets);
        Action advance = () => emulation.RunFor(TimeInterval.FromMicroseconds(100));
        advance();
        foreach(var cpu in cpus) Need((uint)cpu.GetRegister(0) > 0, "Initial native ADD loop never ran");
        Log("BOTH_NATIVE_CORES_RUNNING_BEFORE_RUN_ASSERTION");
        ram.WriteDoubleWord(0, 0x20002f00);
        ram.WriteDoubleWord(4, 0x20000201);

        if(mode == "release_completion" || mode == "reassert_completion")
        {
            using(var entered = new ManualResetEventSlim())
            using(var release = new ManualResetEventSlim())
            {
                var blocked = 0;
                machine.PeripheralReset += (_, peripheral) =>
                {
                    if(peripheral != port || Interlocked.Exchange(ref blocked, 1) != 0) return;
                    entered.Set();
                    Need(release.Wait(TimeSpan.FromSeconds(5)), "Reset completion barrier timed out");
                };
                port.OnGPIO(2, false);
                var reset = Task.Run(advance);
                Need(entered.Wait(TimeSpan.FromSeconds(5)), "Asynchronous machine reset did not reach completion barrier");
                Log("PHYSICAL_EDGE_DURING_PENDING_RESET_COMPLETION mode=" + mode);
                try
                {
                    port.OnGPIO(2, true);
                    if(mode == "reassert_completion") port.OnGPIO(2, false);
                }
                finally { release.Set(); }
                Need(reset.Wait(TimeSpan.FromSeconds(10)), "Reset completion did not finish");
            }
            if(mode == "release_completion")
            {
                Need(Volatile.Read(ref resets) == 1, "Short pulse did not cause exactly one machine reset");
                AssertBooted(cpus);
                AssertProgress(advance, cpus);
                Log("RELEASE_DURING_RESET_BOOTED_WITHOUT_STALE_HOLD");
                return;
            }
            Need(Volatile.Read(ref resets) == 2, "Reassertion lost a reset edge");
        }
        else
        {
            port.OnGPIO(2, false);
            if(mode == "pulse")
            {
                port.OnGPIO(2, true);
                Need(Volatile.Read(ref resets) == 0, "Pulse was not queued before reset execution");
                advance();
                Need(Volatile.Read(ref resets) == 1, "Pulse lost its real machine reset");
                AssertBooted(cpus);
                AssertProgress(advance, cpus);
                Log("SHORT_PULSE_RESET_AND_VECTOR_BOOT_WITHOUT_STALE_HOLD");
                return;
            }
            advance();
            Need(Volatile.Read(ref resets) == 1, "RUN assertion did not reset the machine exactly once");
        }

        AssertHeld(advance, cpus);
        if(mode == "reset_low")
        {
            var before = Volatile.Read(ref resets);
            port.Reset();
            port.OnGPIO(2, false); // repeated low must not create a reset edge
            advance();
            Need(Volatile.Read(ref resets) == before, "Protocol reset/repeated low retriggered physical reset");
            machine.RequestReset();
            advance();
            Need(Volatile.Read(ref resets) == before + 1, "Additional asynchronous machine reset was lost");
            AssertHeld(advance, cpus);
        }
        if(mode == "foreign_hold" || mode == "foreign_release")
        {
            // Same CPU wait/reset contract used by PSM and POWMAN rescue.
            // RUN must be an independent source, with neither owner restoring
            // or overwriting the other owner's GPIO level.
            cpus[1].CpuWaitSignal.Set();
            cpus[1].Reset();
            if(mode == "foreign_release")
            {
                cpus[1].CpuWaitSignal.Unset();
                advance();
                AssertHeld(advance, cpus);
            }
        }
        if(mode == "debug_hold")
        {
            nvics[1].WriteDoubleWord(0xdf0, 0xa05f0003);
            Need(SpinWait.SpinUntil(() => (nvics[1].ReadDoubleWord(0xdf0) & 0x20000) != 0,
                TimeSpan.FromSeconds(5)), "Independent debugger halt was not acknowledged");
        }
        port.OnGPIO(2, true);
        advance();
        if(mode == "foreign_hold" || mode == "debug_hold")
        {
            AssertBooted(new[] { cpus[0] });
            Need(cpus[1].ExecutedInstructions == 0, "RUN release canceled an independent core hold");
            if(mode == "foreign_hold")
            {
                Need(cpus[1].CpuWaitSignal.IsSet, "RUN release changed PSM/power wait state");
                cpus[1].CpuWaitSignal.Unset();
            }
            else
            {
                Need(cpus[1].HaltedByDebugger, "RUN release cleared C_HALT");
                nvics[1].WriteDoubleWord(0xdf0, 0xa05f0001);
                Need(SpinWait.SpinUntil(() => (nvics[1].ReadDoubleWord(0xdf0) & 0x20000) == 0,
                    TimeSpan.FromSeconds(5)), "Debugger resume was not applied");
            }
            advance();
        }
        AssertBooted(cpus);
        AssertProgress(advance, cpus);
        Log("RUN_RELEASE_BOOTED_BOTH_REAL_RESET_VECTORS mode=" + mode + " resets=" + resets);
    }

    static void AssertHeld(Action advance, CortexM[] cpus)
    {
        foreach(var cpu in cpus) Need(cpu.ExecutedInstructions == 0, "A held PE retired instructions after reset");
        for(var window = 0; window < 3; window++)
        {
            advance();
            foreach(var cpu in cpus)
            {
                Need(cpu.ExecutedInstructions == 0 && (uint)cpu.GetRegister(0) == 0 && (uint)cpu.GetRegister(5) == 0,
                    "Native progress while RUN remains low");
            }
        }
        Log("BOTH_PES_RETIRED_ZERO_INSTRUCTIONS_IN_THREE_HELD_WINDOWS");
    }

    static void AssertBooted(CortexM[] cpus)
    {
        foreach(var cpu in cpus)
        {
            Need((uint)cpu.GetRegister(5) == 0x5a && (uint)cpu.GetRegister(13) == 0x20002f00,
                "Release did not load the real reset vector and MSP");
            Need((uint)cpu.GetRegister(0) > 0 && cpu.ExecutedInstructions > 0, "Released native ADD loop never executed");
        }
    }

    static void AssertProgress(Action advance, CortexM[] cpus)
    {
        var before = Array.ConvertAll(cpus, cpu => cpu.ExecutedInstructions);
        advance();
        for(var i = 0; i < cpus.Length; i++) Need(cpus[i].ExecutedInstructions > before[i], "Released PE stopped after first window");
    }
}
