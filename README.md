picoatxt is an AT and XT compatible USB keyboard converter for the Raspberry Pi Pico.

To build, use cmake as expected. You will need `zig` in your PATH as well as the usual tools necessary to build with the Pico SDK.

On Windows, you may have to use a build system that isn't msbuild, e.g. ``cmake .. -G "NMake Makefiles"``.

On Linux, make sure your GCC cross compiler does not come from apt, because it is slightly broken. You can either compile your own, or download one directly from ARM.

For pin assignments, connect `clk_in` to GPIO21, `data_in` to GPIO20, `clk_out` to GPIO11, `data_out` to GPIO10. The reset line is not supported. +5v and ground should come from USB.

The clk and data lines are 5v which can't directly be connected to the pico without damaging it. So, you will need a level shifting arrangement. Here, the levels are flipped: when a data line is high, the `in` pin should be low, and vice-versa.
Meanwhile, if an `out` pin is high, the corresponding line should be forced low, otherwise, it is controlled by the keyboard. This can be done easily with a CMOS arrangement or with NPNs where the emitters are tied to ground.
