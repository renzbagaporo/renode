// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
using System;
using System.Reflection;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

using Antmicro.Renode.Core;
using Antmicro.Renode.Exceptions;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;
using Antmicro.Renode.Peripherals.IRQControllers;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    // Test-only barriers wrap the real bound native delegates. They force the
    // publication windows without adding hooks to the production CPU model.
    public class RP2350RcpConcurrencyTester : IDoubleWordPeripheral, IKnownSize
    {
        public RP2350RcpConcurrencyTester(IMachine machine, CortexM cpu0, CortexM cpu1)
        {
            this.machine = machine;
            this.cpu0 = cpu0;
            this.cpu1 = cpu1;
        }

        public void FaultThenReset()
        {
            using(var written = new ManualResetEventSlim())
            using(var release = new ManualResetEventSlim())
            using(var resetStarted = new ManualResetEventSlim())
            {
                var field = Field(typeof(CortexM), "tlibRp2350RcpSetFault");
                var original = (Action)field.GetValue(cpu0);
                field.SetValue(cpu0, (Action)(() => { original(); written.Set(); Wait(release); }));
                try
                {
                    var fault = Task.Run(() => Fault(cpu1));
                    Wait(written);
                    var reset = Task.Run(() => { resetStarted.Set(); cpu0.Reset(); });
                    Wait(resetStarted);
                    // The target reset monitor must be held across native fault
                    // publication and assertion of its associated NMI level.
                    Assert(MonitorOwnedByAnotherThread(ResetMonitor(cpu0)), "Fault publication did not own the target reset monitor");
                    release.Set();
                    Join(fault, reset);
                }
                finally { release.Set(); field.SetValue(cpu0, original); }
            }
            AssertState(cpu0, false, false);
        }

        public void ResetThenFault()
        {
            WithPausedReset(cpu0, () => Fault(cpu1));
            AssertState(cpu0, true, false);
        }

        public void SaltThenReset()
        {
            using(var written = new ManualResetEventSlim())
            using(var release = new ManualResetEventSlim())
            using(var resetStarted = new ManualResetEventSlim())
            {
                var field = Field(typeof(CortexM), "tlibRp2350RcpSetSalt");
                var original = (Func<ulong, uint>)field.GetValue(cpu1);
                field.SetValue(cpu1, (Func<ulong, uint>)(salt => { var result = original(salt); written.Set(); Wait(release); return result; }));
                try
                {
                    var salt = Task.Run(() => Assert(Salt(1) == 1, "Salt initialization failed"));
                    Wait(written);
                    var reset = Task.Run(() => { resetStarted.Set(); cpu1.Reset(); });
                    Wait(resetStarted);
                    Assert(MonitorOwnedByAnotherThread(ResetMonitor(cpu1)), "Salt publication did not own the target reset monitor");
                    release.Set();
                    Join(salt, reset);
                }
                finally { release.Set(); field.SetValue(cpu1, original); }
            }
            AssertState(cpu1, false, false);
        }

        public void ResetThenSalt()
        {
            WithPausedReset(cpu1, () => Assert(Salt(1) == 1, "Salt initialization after reset failed"));
            AssertState(cpu1, false, true);
            Run(cpu1, 0xfe132734);
            Assert(cpu1.GetRegister(2).RawValue == 0x9f8eef00, "Published canary salt was torn");
        }

        public void SimultaneousNativeFaults()
        {
            using(var firstFault = new ManualResetEventSlim())
            using(var secondStarted = new ManualResetEventSlim())
            using(var release = new ManualResetEventSlim())
            {
                // Hold core 0's fault callback before it can fault core 1. Core 1
                // can then independently detect its own real RCP assertion.
                var field = Field(typeof(CortexM), "tlibRp2350RcpSetFault");
                var original = (Action)field.GetValue(cpu0);
                var entries = 0;
                field.SetValue(cpu0, (Action)(() =>
                {
                    original();
                    if(Interlocked.Increment(ref entries) == 1) { firstFault.Set(); Wait(release); }
                }));
                try
                {
                    Prepare(cpu0, 0x1000, 0xfc410770);
                    Prepare(cpu1, 0x1100, 0xfc410770);
                    var first = Task.Run(() => Execute(cpu0));
                    Wait(firstFault);
                    Thread secondThread = null;
                    var second = Task.Run(() => { secondThread = Thread.CurrentThread; secondStarted.Set(); Execute(cpu1); });
                    Wait(secondStarted);
                    Assert(SpinWait.SpinUntil(() => second.IsCompleted || (secondThread.ThreadState & ThreadState.WaitSleepJoin) != 0,
                        TimeSpan.FromSeconds(10)) && !second.IsCompleted, "Second native fault did not reach the shared target monitor");
                    release.Set();
                    Join(first, second);
                }
                finally { release.Set(); field.SetValue(cpu0, original); }
            }
            Assert(Nmi(cpu0) && Nmi(cpu1), "Simultaneous native faults did not assert both NMIs");
        }

        public void LivePeerPublicationAndFault()
        {
            using(var running = new ManualResetEventSlim())
            using(var initialized = new ManualResetEventSlim())
            using(var interrupted = new ManualResetEventSlim())
            {
                var callerThread = Thread.CurrentThread.ManagedThreadId;
                var workerThread = callerThread;
                Action<ulong, uint> hook = (address, size) =>
                {
                    workerThread = Thread.CurrentThread.ManagedThreadId;
                    running.Set();
                    if(cpu1.GetRegister(2).RawValue == 0x9f8eef00) initialized.Set();
                    if(address == 0x4000) interrupted.Set();
                };
                cpu1.CPACR = 0xc000;
                cpu1.SP = 0x8000;
                cpu1.PC = 0x5000;
                machine.SystemBus.WriteDoubleWord(0x5000, 0xf710fe30);
                machine.SystemBus.WriteWord(0x5004, 0xd5fc);
                machine.SystemBus.WriteDoubleWord(0x5006, 0x2734fe13);
                machine.SystemBus.WriteWord(0x500a, 0xe7f9);
                cpu1.ClearTranslationCache();
                cpu0.IsHalted = true;
                cpu1.SetHookAtBlockBegin(hook);
                cpu1.ExecutionMode = ExecutionMode.Continuous;
                try
                {
                    EmulationManager.Instance.CurrentEmulation.StartAll();
                    Assert(running.Wait(TimeSpan.FromSeconds(10)), "Peer did not start: PC=" + cpu1.PC + " paused=" + cpu1.IsPaused + " halted=" + cpu1.IsHalted);
                    Assert(workerThread != callerThread, "Peer did not execute on its CPU thread");
                    Assert(Salt(1) == 1, "Live peer salt initialization failed");
                    Assert(initialized.Wait(TimeSpan.FromSeconds(10)), "Live peer did not observe published salt: PC=" + cpu1.PC + " r2=" + cpu1.GetRegister(2));
                    Fault(cpu0);
                    Assert(interrupted.Wait(TimeSpan.FromSeconds(10)), "Live peer did not enter NMI: PC=" + cpu1.PC);
                }
                finally
                {
                    EmulationManager.Instance.CurrentEmulation.PauseAll();
                    cpu1.SetHookAtBlockBegin(null);
                    cpu1.ExecutionMode = ExecutionMode.SingleStep;
                }
                Assert(Nmi(cpu1), "Live peer lost its fault NMI");
                cpu1.Reset();
                AssertState(cpu1, false, false);
            }
        }

        public uint ReadDoubleWord(long offset) => 0;
        public void WriteDoubleWord(long offset, uint value) { }
        public void Reset() { }
        public long Size => 4;

        private void WithPausedReset(CortexM target, Action publish)
        {
            using(var cleared = new ManualResetEventSlim())
            using(var release = new ManualResetEventSlim())
            using(var publishStarted = new ManualResetEventSlim())
            {
                var field = Field(typeof(TranslationCPU), "TlibReset");
                var original = (Action)field.GetValue(target);
                field.SetValue(target, (Action)(() => { original(); cleared.Set(); Wait(release); }));
                try
                {
                    var reset = Task.Run(() => target.Reset());
                    Wait(cleared);
                    var writer = Task.Run(() => { publishStarted.Set(); publish(); });
                    Wait(publishStarted);
                    Assert(!writer.Wait(TimeSpan.FromMilliseconds(100)), "Publication passed a reset in progress");
                    release.Set();
                    Join(reset, writer);
                }
                finally { release.Set(); field.SetValue(target, original); }
            }
        }

        private void AssertState(CortexM target, bool fault, bool valid)
        {
            Assert(Nmi(target) == fault, "Native fault and NMI disagree after reset/publication");
            var nvic = (NVIC)Field(typeof(CortexM), "nvic").GetValue(target);
            // Remove the NMI level in the fixture so the actual RCP opcode can
            // distinguish a sticky native fault from an initialized/empty salt.
            nvic.OnGPIO(-14, false);
            nvic.WriteDoubleWord(0xd04, 0x40000000);
            Run(target, 0xfe300710);
            Assert(target.PC.RawValue == (fault ? 0x4000u : 0x1004u), "Native RCP fault state disagrees with reset/publication: PC=" + target.PC + " expectedFault=" + fault);
            if(!fault) Assert(target.GetRegister(0).RawValue == (valid ? 0xa500a500u : 0x00c300c3u), "Native salt valid state disagrees with reset/publication");
        }

        private bool Nmi(CortexM target)
        {
            var nvic = (NVIC)Field(typeof(CortexM), "nvic").GetValue(target);
            return ((HashSet<int>)Field(typeof(NVIC), "assertedExternalIRQs").GetValue(nvic)).Contains(2);
        }

        private void Run(CortexM target, uint opcode)
        {
            Prepare(target, 0x1000, opcode);
            Execute(target);
        }

        private void Prepare(CortexM target, uint address, uint opcode)
        {
            // These cases drive the real native instruction budget directly
            // from fixture worker threads while the machine is paused. Avoid
            // SingleStep's block callback, which waits for scheduler step grants.
            target.ExecutionMode = ExecutionMode.Continuous;
            target.CPACR = 0xc000;
            target.SP = 0x8000;
            target.PC = address;
            machine.SystemBus.WriteDoubleWord(address, (opcode << 16) | (opcode >> 16));
            target.ClearTranslationCache();
        }

        private static void Execute(CortexM target)
        {
            for(var attempt = 0; attempt < 8; attempt++)
            {
                ulong executed;
                var result = target.ExecuteInstructions(1, out executed);
                if(executed != 0 || result == ExecutionResult.WaitingForInterrupt) return;
            }
            throw new RecoverableException("Native execution did not retire an opcode: PC=" + target.PC);
        }

        private uint Salt(uint core) => (uint)typeof(CortexM).GetMethod("RP2350RcpWriteSalt", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(cpu0, new object[] { core, 0x0123456789abcdefUL });
        private static void Fault(CortexM source) => typeof(CortexM).GetMethod("RP2350RcpFault", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(source, new object[] { 0u });
        private static bool MonitorOwnedByAnotherThread(object monitor)
        {
            if(!Monitor.TryEnter(monitor)) return true;
            Monitor.Exit(monitor);
            return false;
        }

        private static object ResetMonitor(CortexM cpu) => Field(typeof(CortexM), "reset").GetValue(cpu);
        private static FieldInfo Field(Type type, string name) => type.GetField(name, BindingFlags.Instance | BindingFlags.NonPublic);
        private static void Wait(ManualResetEventSlim signal) => Assert(signal.Wait(TimeSpan.FromSeconds(10)), "Concurrency barrier timed out");
        private static void Join(params Task[] tasks) => Assert(Task.WaitAll(tasks, TimeSpan.FromSeconds(10)), "Concurrent RCP operations deadlocked");
        private static void Assert(bool condition, string message) { if(!condition) throw new RecoverableException(message); }

        private readonly IMachine machine;
        private readonly CortexM cpu0;
        private readonly CortexM cpu1;
    }
}
