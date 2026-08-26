`timescale 1ns/1ps

module tb_mt32pi;

logic       clk_audio = 1'b0;
logic       clk_video = 1'b0;
logic       ce_pixel = 1'b1;
logic       vga_vs = 1'b0;
logic       vga_de = 1'b0;
logic [6:0] user_in = 7'h09;
wire  [6:0] user_out;
logic       reset = 1'b1;
logic       midi_tx = 1'b1;
wire        midi_rx;
wire [15:0] mt32_i2s_r;
wire [15:0] mt32_i2s_l;
wire        mt32_available;
logic       mt32_mode_req = 1'b1;
logic [1:0] mt32_rom_req = 2'd2;
logic [7:0] mt32_sf_req = 8'd5;
wire  [7:0] mt32_mode;
wire  [7:0] mt32_rom;
wire  [7:0] mt32_sf;
wire        mt32_newmode;
wire        mt32_lcd_en;
wire        mt32_lcd_pix;
wire        mt32_lcd_update;

always #5 clk_audio = ~clk_audio;
always #7 clk_video = ~clk_video;

mt32pi dut
(
	.CLK_AUDIO       (clk_audio),
	.CLK_VIDEO       (clk_video),
	.CE_PIXEL        (ce_pixel),
	.VGA_VS          (vga_vs),
	.VGA_DE          (vga_de),
	.USER_IN         (user_in),
	.USER_OUT        (user_out),
	.reset           (reset),
	.midi_tx         (midi_tx),
	.midi_rx         (midi_rx),
	.mt32_i2s_r      (mt32_i2s_r),
	.mt32_i2s_l      (mt32_i2s_l),
	.mt32_available  (mt32_available),
	.mt32_mode_req   (mt32_mode_req),
	.mt32_rom_req    (mt32_rom_req),
	.mt32_sf_req     (mt32_sf_req),
	.mt32_mode       (mt32_mode),
	.mt32_rom        (mt32_rom),
	.mt32_sf         (mt32_sf),
	.mt32_newmode    (mt32_newmode),
	.mt32_lcd_en     (mt32_lcd_en),
	.mt32_lcd_pix    (mt32_lcd_pix),
	.mt32_lcd_update (mt32_lcd_update)
);

task automatic audio_wait(input integer cycles);
	repeat (cycles) @(posedge clk_audio);
	#1;
endtask

task automatic i2c_drive(input logic scl, input logic sda);
	user_in[3] = scl;
	user_in[0] = sda;
	audio_wait(32);
endtask

task automatic i2c_start;
	i2c_drive(1'b1, 1'b1);
	i2c_drive(1'b1, 1'b0);
	if (dut.i2c_cnt !== 4'd9)
		$fatal(1, "MT32-pi I2C start was not detected (cnt=%0d)", dut.i2c_cnt);
	i2c_drive(1'b0, 1'b0);
endtask

task automatic i2c_stop;
	i2c_drive(1'b0, 1'b0);
	i2c_drive(1'b1, 1'b0);
	i2c_drive(1'b1, 1'b1);
endtask

task automatic i2c_write_byte(input logic [7:0] value);
	integer bit_index;
	for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
		i2c_drive(1'b0, value[bit_index]);
		i2c_drive(1'b1, value[bit_index]);
		i2c_drive(1'b0, value[bit_index]);
	end
	user_in[0] = 1'b1;
	i2c_drive(1'b1, 1'b1);
	if (user_out[0] !== 1'b0)
		$fatal(1, "MT32-pi I2C byte was not acknowledged (cnt=%0d bcnt=%0d tmp=%02x)",
		       dut.i2c_cnt, dut.i2c_bcnt, dut.i2c_tmp);
	i2c_drive(1'b0, 1'b1);
endtask

task automatic i2c_read_byte(output logic [7:0] value);
	integer bit_index;
	user_in[0] = 1'b1;
	for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
		i2c_drive(1'b1, 1'b1);
		value[bit_index] = user_out[0];
		i2c_drive(1'b0, 1'b1);
	end
	user_in[0] = 1'b0;
	i2c_drive(1'b1, 1'b0);
	i2c_drive(1'b0, 1'b0);
	user_in[0] = 1'b1;
endtask

task automatic read_config(
	output logic [7:0] mode,
	output logic [7:0] rom,
	output logic [7:0] soundfont
);
	i2c_start();
	i2c_write_byte(8'h8B);
	i2c_read_byte(mode);
	i2c_read_byte(rom);
	i2c_read_byte(soundfont);
	i2c_stop();
endtask

task automatic write_status(
	input logic [7:0] mode,
	input logic [7:0] rom,
	input logic [7:0] soundfont
);
	i2c_start();
	i2c_write_byte(8'h8A);
	i2c_write_byte(mode);
	i2c_write_byte(rom);
	i2c_write_byte(soundfont);
	i2c_stop();
endtask

task automatic i2s_clock(input logic level);
	user_in[6] = level;
	audio_wait(4);
endtask

task automatic i2s_send_word(input logic [15:0] value, input logic ws);
	integer bit_index;
	user_in[5] = ws;
	for (bit_index = 15; bit_index >= 0; bit_index = bit_index - 1) begin
		user_in[2] = value[bit_index];
		i2s_clock(1'b0);
		i2s_clock(1'b1);
		i2s_clock(1'b0);
	end
endtask

task automatic i2s_finish_word(input logic next_ws);
	user_in[5] = next_ws;
	i2s_clock(1'b1);
	i2s_clock(1'b0);
	audio_wait(8);
endtask

initial begin
	logic [7:0] read_mode;
	logic [7:0] read_rom;
	logic [7:0] read_sf;
	logic       old_newmode;
	logic       old_lcd_update;
	logic       lcd_pixel_seen;
	integer     pixel_cycle;

	// Keep cable selection deterministic while exercising the straight-cable mapping.
	force dut.crossed = 1'b0;
	user_in[6] = 1'b0;
	audio_wait(20);
	reset = 1'b0;
	audio_wait(40);

	if (mt32_available !== 1'b0) $fatal(1, "MT32-pi availability did not clear on reset");
	if (mt32_i2s_l !== 16'd0 || mt32_i2s_r !== 16'd0)
		$fatal(1, "MT32-pi I2S samples did not clear on reset");
	if (user_out[6:2] !== 5'b11111) $fatal(1, "Unused USER_OUT pins are not idle-high");
	midi_tx = 1'b0;
	audio_wait(2);
	if (user_out[1] !== 1'b0) $fatal(1, "MIDI TX low was not routed to USER_OUT[1]");
	midi_tx = 1'b1;
	audio_wait(2);
	if (user_out[1] !== 1'b1) $fatal(1, "MIDI TX high was not routed to USER_OUT[1]");

	// Unattached USER pins can look like an I2S stream.  They must remain
	// silent until valid I2C traffic identifies an MT32-pi.
	i2s_send_word(16'hA55A, 1'b0);
	i2s_finish_word(1'b1);
	if (mt32_i2s_l !== 16'd0 || mt32_i2s_r !== 16'd0)
		$fatal(1, "Undetected MT32-pi leaked USER-port I2S into audio");
	reset = 1'b1;
	audio_wait(4);
	reset = 1'b0;
	audio_wait(4);

	// The first request after reset must ask MT32-pi to reset; later requests carry defaults.
	read_config(read_mode, read_rom, read_sf);
	if (read_mode !== 8'hA0 || read_rom !== 8'd2 || read_sf !== 8'd5)
		$fatal(1, "Unexpected reset config: mode=%02x rom=%02x sf=%02x", read_mode, read_rom, read_sf);
	read_config(read_mode, read_rom, read_sf);
	if (read_mode !== 8'hA2 || read_rom !== 8'd2 || read_sf !== 8'd5)
		$fatal(1, "Unexpected default config: mode=%02x rom=%02x sf=%02x", read_mode, read_rom, read_sf);

	old_newmode = mt32_newmode;
	write_status(8'hA2, 8'd2, 8'd5);
	if (!mt32_available) $fatal(1, "Valid MT32-pi I2C traffic did not set availability");
	if (mt32_mode !== 8'hA2 || mt32_rom !== 8'd2 || mt32_sf !== 8'd5)
		$fatal(1, "MT32-pi status response was not captured");
	if (mt32_newmode === old_newmode) $fatal(1, "MT32-pi mode-change toggle did not update");
	user_in[4] = 1'b0;
	audio_wait(2);
	if (midi_rx !== 1'b0) $fatal(1, "Straight-cable MIDI RX low was not routed");
	user_in[4] = 1'b1;
	audio_wait(2);
	if (midi_rx !== 1'b1) $fatal(1, "Straight-cable MIDI RX high was not routed");

	// I2S words are committed when WS changes to mark the next channel.
	i2s_send_word(16'hA55A, 1'b0);
	i2s_finish_word(1'b1);
	if (mt32_i2s_l !== 16'hA55A) $fatal(1, "Left I2S sample mismatch: %04x", mt32_i2s_l);
	i2s_send_word(16'h3CC3, 1'b1);
	i2s_finish_word(1'b0);
	if (mt32_i2s_r !== 16'h3CC3) $fatal(1, "Right I2S sample mismatch: %04x", mt32_i2s_r);

	// Write one all-on LCD byte and verify both the update toggle and rendered pixel output.
	old_lcd_update = mt32_lcd_update;
	i2c_start();
	i2c_write_byte(8'h78);
	i2c_write_byte(8'h40);
	i2c_write_byte(8'hFF);
	i2c_stop();
	if (mt32_lcd_update === old_lcd_update) $fatal(1, "LCD update toggle did not change");

	vga_de = 1'b0;
	vga_vs = 1'b0;
	repeat (4) @(posedge clk_video);
	vga_vs = 1'b1;
	repeat (4) @(posedge clk_video);
	vga_vs = 1'b0;
	repeat (12) @(posedge clk_video);
	vga_de = 1'b1;
	lcd_pixel_seen = 1'b0;
	for (pixel_cycle = 0; pixel_cycle < 40; pixel_cycle = pixel_cycle + 1) begin
		@(posedge clk_video);
		if (mt32_lcd_en && mt32_lcd_pix) lcd_pixel_seen = 1'b1;
	end
	if (!lcd_pixel_seen) $fatal(1, "LCD data was not rendered into the video overlay");

	$display("PASS: MT32-pi protocol, MIDI, I2S, and LCD simulation");
	$finish;
end

endmodule
