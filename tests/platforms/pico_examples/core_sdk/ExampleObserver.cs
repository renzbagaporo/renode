//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//

using System;
using System.Collections.Generic;
using System.IO;

using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;
using Antmicro.Renode.Peripherals.GPIOPort;
using Antmicro.Renode.Peripherals.Memory;
using Antmicro.Renode.Peripherals.UART;
using Antmicro.Renode.Time;

using Newtonsoft.Json;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    // Test-only observations. No firmware memory/register write or protocol
    // response is provided. An optional address breakpoint halts execution at
    // the observed instruction before it executes, as a debugger would.
    public sealed class PicoExampleObserver : IPeripheral
    {
        public PicoExampleObserver(IMachine machine, MappedMemory memory = null)
        {
            this.machine = machine;
            observedMemory = memory;
        }

        public string GetConfiguredNativeEngines()
        {
            var result = new List<object>();
            var nativeFile = typeof(TranslationCPU).GetField("libraryFile",
                System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
            foreach(var cpu in machine.SystemBus.GetCPUs())
            {
                var translation = cpu as TranslationCPU;
                if(translation == null) throw new InvalidOperationException("Configured CPU is not a native translation engine");
                result.Add(new { name = machine.GetLocalName(cpu), type = cpu.GetType().FullName,
                    architecture = translation.Architecture, gdb_architecture = translation.GDBArchitecture, core = cpu.MultiprocessingId,
                    native_path = (string)nativeFile.GetValue(translation),
                    halted = cpu.IsHalted, pc = cpu.PC.RawValue,
                    executed_instructions = translation.ExecutedInstructions });
            }
            return JsonConvert.SerializeObject(result);
        }

        public void ObserveGPIO(RP2_GPIOBank0 gpio, int selectedPin)
        {
            gpio.DriveChanged += (pin, level, enabled) =>
            {
                if(pin != selectedPin) return;
                lock(sync) events.Add(new { kind = "gpio", pin, level, enabled, seconds = Now });
            };
        }

        public void ObserveUART(IUART uart)
        {
            var name = machine.GetLocalName(uart);
            uart.CharReceived += value =>
            {
                lock(sync) events.Add(new { kind = "uart", uart = name, value, seconds = Now });
            };
        }

        public void ObserveCPU(CortexM cpu)
        {
            cpu.AddHookAtInterruptBegin(irq =>
            {
                // TranslationCPU reports the architecture's exception kind
                // here (ARM EXCP_IRQ=5), before NVIC chooses a vector.
                var entry = new { kind = "interrupt", core = cpu.MultiprocessingId,
                    exception_kind = irq, seconds = Now };
                lock(sync)
                {
                    events.Add(entry);
                    if(faultKinds.Contains((int)irq)) milestones.Add(entry);
                }
            });
        }

        public void ObserveAddress(CortexM cpu, ulong address, string label, bool halt = false)
        {
            cpu.AddHook(address & ~1ul, (core, pc) =>
            {
                RecordAddress(new { kind = "address", label, pc, core = core.MultiprocessingId,
                    r0 = core.GetRegister(0).RawValue, r1 = core.GetRegister(1).RawValue,
                    r2 = core.GetRegister(2).RawValue, sp = core.GetRegister(13).RawValue,
                    lr = core.GetRegister(14).RawValue, ipsr = cpu.XProgramStatusRegister & 0x1ff,
                    seconds = Now, halted = halt }, label);
                if(halt) core.IsHalted = true;
            });
        }

        public void ObserveFunctionReturn(CortexM cpu, ulong address, string label)
        {
            cpu.AddHook(address & ~1ul, (core, pc) =>
            {
                var returnAddress = core.GetRegister(14).RawValue & ~1ul;
                var returned = false;
                cpu.AddHook(returnAddress, (returnCore, returnPc) =>
                {
                    if(returned) return;
                    returned = true;
                    RecordAddress(new { kind = "address", label = label + "_return",
                        pc = returnPc, core = returnCore.MultiprocessingId,
                        r0 = returnCore.GetRegister(0).RawValue,
                        sp = returnCore.GetRegister(13).RawValue,
                        ipsr = cpu.XProgramStatusRegister & 0x1ff, seconds = Now, halted = false }, label + "_return");
                });
            });
        }

        public void ObservePeripheral(IBusPeripheral peripheral, ulong addressBase)
        {
            machine.SystemBus.SetHookAfterPeripheralRead<byte>(peripheral, (value, offset) =>
            {
                RecordRegister(addressBase, offset, value, "Read", 8);
                return value;
            });
            machine.SystemBus.SetHookBeforePeripheralWrite<byte>(peripheral, (value, offset) =>
            {
                RecordRegister(addressBase, offset, value, "Write", 8);
                return value;
            });
            machine.SystemBus.SetHookAfterPeripheralRead<ushort>(peripheral, (value, offset) =>
            {
                RecordRegister(addressBase, offset, value, "Read", 16);
                return value;
            });
            machine.SystemBus.SetHookBeforePeripheralWrite<ushort>(peripheral, (value, offset) =>
            {
                RecordRegister(addressBase, offset, value, "Write", 16);
                return value;
            });
            machine.SystemBus.SetHookAfterPeripheralRead<uint>(peripheral, (value, offset) =>
            {
                RecordRegister(addressBase, offset, value, "Read", 32);
                return value;
            });
            machine.SystemBus.SetHookBeforePeripheralWrite<uint>(peripheral, (value, offset) =>
            {
                RecordRegister(addressBase, offset, value, "Write", 32);
                return value;
            });
        }

        private void RecordRegister(ulong addressBase, long offset, uint value, string operation, int width)
        {
            machine.SystemBus.TryGetCurrentCPU(out var core);
            lock(sync) events.Add(new { kind = "register", address = addressBase + (ulong)offset,
                operation, value, width, core = core == null ? (uint?)null : core.MultiprocessingId,
                pc = core == null ? (ulong?)null : core.PC.RawValue, seconds = Now });
        }

        public string GetEvents()
        {
            lock(sync) return JsonConvert.SerializeObject(events);
        }

        public string GetMilestones()
        {
            lock(sync) return JsonConvert.SerializeObject(milestones);
        }

        private void RecordAddress(object entry, string label)
        {
            lock(sync)
            {
                events.Add(entry);
                if(!highFrequencyLabels.Contains(label)) milestones.Add(entry);
            }
        }

        public void DumpObservedMemory(string path, long offset, int count)
        {
            if(observedMemory == null) throw new InvalidOperationException("No observed memory was configured");
            File.WriteAllBytes(path, observedMemory.ReadBytes(offset, count));
        }

        public void Reset()
        {
            lock(sync) events.Add(new { kind = "machine_reset", seconds = Now });
        }

        private double Now => TimeDomainsManager.Instance.TryGetVirtualTimeStamp(out var stamp)
            ? stamp.TimeElapsed.TotalSeconds : machine.ElapsedVirtualTime.TimeElapsed.TotalSeconds;

        private readonly IMachine machine;
        private readonly MappedMemory observedMemory;
        private readonly object sync = new object();
        private readonly List<object> events = new List<object>();
        private readonly List<object> milestones = new List<object>();
        private readonly HashSet<string> highFrequencyLabels = new HashSet<string>
        {
            "xPortSysTickHandler", "xPortPendSVHandler", "SysTick_Handler", "PendSV_Handler", "vTaskSwitchContext"
        };
        private readonly HashSet<int> faultKinds = new HashSet<int> { 1, 3, 4, 7, 16, 17, 18, 19, 20, 21 };
    }
}
