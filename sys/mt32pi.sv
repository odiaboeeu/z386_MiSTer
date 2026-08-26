//
// Communication module to MT32-pi (external MIDI emulator on RPi)
// (C) 2020 Sorgelig, Kitrinx
//
// https://github.com/dwhinham/mt32-pi
//

module mt32pi
(
	input             CLK_AUDIO,

	input             CLK_VIDEO,
	input             CE_PIXEL,
	input             VGA_VS,
	input             VGA_DE,

	input       [6:0] USER_IN,
	output      [6:0] USER_OUT,

	input             reset,
	input             midi_tx,
	output            midi_rx,

	output reg [15:0] mt32_i2s_r,
	output reg [15:0] mt32_i2s_l,

	output reg        mt32_available,

	input             mt32_mode_req,
	input       [1:0] mt32_rom_req,
	input       [7:0] mt32_sf_req,

	output reg  [7:0] mt32_mode,
	output reg  [7:0] mt32_rom,
	output reg  [7:0] mt32_sf,
	output reg        mt32_newmode,

	output reg        mt32_lcd_en,
	output reg        mt32_lcd_pix,
	output reg        mt32_lcd_update
);

//
// Pin | USB Name | Signal
// ----+----------+--------------
// 0   | D+       | I/O I2C_SDA / RX (midi in)
// 1   | D-       | O   TX (midi out)
// 2   | TX-      | I   I2S_WS (1 == right)
// 3   | GND_d    | I   I2C_SCL
// 4   | RX+      | I   I2S_BCLK
// 5   | RX-      | I   I2S_DAT
// 6   | TX+      | -   none
//

assign USER_OUT[0]   = sda_out;
assign USER_OUT[1]   = midi_tx;
assign USER_OUT[6:2] = '1;


//
// crossed/straight cable selection
//

generate
	genvar i;
	for(i = 0; i<2; i++) begin : clk_rate
		wire clk_in = i ? USER_IN[6] : USER_IN[4];
		reg [4:0] cnt = 0;
		reg [4:0] cnt_tmp = 0;
		reg       clk_sr = 0;
		reg       clk = 0;
		reg       old_clk = 0;
		always @(posedge CLK_AUDIO) begin : clkr
			clk_sr <= clk_in;
			if (clk_sr == clk_in) clk <= clk_sr;

			if(~&cnt_tmp) cnt_tmp <= cnt_tmp + 1'd1;
			else cnt <= '1;

			old_clk <= clk;
			if(~old_clk & clk) begin
				cnt <= cnt_tmp;
				cnt_tmp <= 0;
			end
		end
	end
	
	reg crossed = 0;
	always @(posedge CLK_AUDIO) crossed <= (clk_rate[0].cnt <= clk_rate[1].cnt);
endgenerate

wire   i2s_ws   = crossed ? USER_IN[2] : USER_IN[5];
wire   i2s_data = crossed ? USER_IN[5] : USER_IN[2];
wire   i2s_bclk = crossed ? USER_IN[4] : USER_IN[6];
assign midi_rx  = ~mt32_available ? USER_IN[0] : crossed ? USER_IN[6] : USER_IN[4];


//
// i2s receiver
//

reg [15:0] i2s_buf = 0;
reg  [4:0] i2s_cnt = 0;
reg        i2s_clk_sr = 0;
reg        i2s_clk = 0;
reg        i2s_old_clk = 0;
reg        i2s_old_ws = 0;
reg        i2s_next = 0;

always @(posedge CLK_AUDIO) begin : i2s_proc
	// Debounce clock
	i2s_clk_sr <= i2s_bclk;
	if (i2s_clk_sr == i2s_bclk) i2s_clk <= i2s_clk_sr;

	// Latch data and ws on rising edge
	i2s_old_clk <= i2s_clk;
	if (i2s_clk && ~i2s_old_clk) begin

		if (~i2s_cnt[4]) begin
			i2s_cnt <= i2s_cnt + 1'd1;
			i2s_buf[~i2s_cnt[3:0]] <= i2s_data;
		end

		// Word Select will change 1 clock before the new word starts
		i2s_old_ws <= i2s_ws;
		if (i2s_old_ws != i2s_ws) i2s_next <= 1;
	end

	if (i2s_next) begin
		i2s_next <= 0;
		i2s_cnt <= 0;
		i2s_buf <= 0;

		// USER_IN may toggle when no MT32-pi is attached.  Do not expose those
		// asynchronous pins to the audio mixer until the I2C handshake has
		// positively identified the device.
		if (mt32_available) begin
			if (i2s_ws) mt32_i2s_l <= i2s_buf;
			else        mt32_i2s_r <= i2s_buf;
		end
	end
	
	if (reset) begin
		i2s_buf    <= 0;
		i2s_cnt    <= 0;
		i2s_clk_sr <= 0;
		i2s_clk    <= 0;
		i2s_old_clk <= 0;
		i2s_old_ws <= 0;
		i2s_next   <= 0;
		mt32_i2s_l <= 0;
		mt32_i2s_r <= 0;
	end
end


//
// i2c slave
//

reg        sda_out;
reg  [7:0] lcd_data[1024];
reg        lcd_sz;

reg        reset_r  = 0;
wire [7:0] mode_req = reset_r ? 8'hA0 : mt32_mode_req ? 8'hA2 : 8'hA1;
wire [7:0] rom_req  = {6'd0, mt32_rom_req};

reg        i2c_sda_sr = 1;
reg        i2c_scl_sr = 1;
reg        i2c_old_sda = 1;
reg        i2c_old_scl = 1;
reg        i2c_sda = 1;
reg        i2c_scl = 1;
reg  [7:0] i2c_tmp = 0;
reg  [3:0] i2c_cnt = 0;
reg [10:0] i2c_bcnt = 0;
reg        i2c_ack = 0;
reg        i2c_rw = 0;
reg        i2c_disp = 0;
reg        i2c_dispdata = 0;
reg  [2:0] i2c_div = 0;

always @(posedge CLK_AUDIO) begin : i2c_slave
	i2c_div <= i2c_div + 1'd1;
	if(i2c_div == 0) begin
		i2c_sda_sr <= USER_IN[0];
		if(i2c_sda_sr == USER_IN[0]) i2c_sda <= i2c_sda_sr;
		i2c_old_sda <= i2c_sda;

		i2c_scl_sr <= USER_IN[3];
		if(i2c_scl_sr == USER_IN[3]) i2c_scl <= i2c_scl_sr;
		i2c_old_scl <= i2c_scl;

		//start
		if(i2c_old_scl & i2c_scl & i2c_old_sda & ~i2c_sda) begin
			i2c_cnt <= 9;
			i2c_bcnt <= 0;
			i2c_ack <= 0;
			i2c_rw <= 0;
			i2c_disp <= 0;
			i2c_dispdata <= 0;
		end

		//stop
		if(i2c_old_scl & i2c_scl & ~i2c_old_sda & i2c_sda) begin
			i2c_cnt <= 0;
			if(i2c_dispdata) begin
				lcd_sz <= ~i2c_bcnt[9];
				mt32_lcd_update <= ~mt32_lcd_update;
			end
		end

		//data latch
		if(~i2c_old_scl && i2c_scl && (i2c_cnt != 0)) begin
			i2c_tmp <= {i2c_tmp[6:0], i2c_sda};
			i2c_cnt <= i2c_cnt - 1'd1;
		end

		if(i2c_cnt == 0) sda_out <= 1;

		//data set
		if(i2c_old_scl && ~i2c_scl) begin
			sda_out <= 1;
			if(i2c_cnt == 1) begin
				if(i2c_bcnt == 0) begin
					if(i2c_tmp[7:1] == 'h45 || i2c_tmp[7:1] == 'h3c) begin
						i2c_disp <= (i2c_tmp[7:1] == 'h3c);
						sda_out <= 0;
						mt32_available <= 1;
						i2c_ack <= 1;
						i2c_rw <= i2c_tmp[0];
						i2c_bcnt <= i2c_bcnt + 1'd1;
						i2c_cnt <= 10;
					end
					else begin
						// wrong address, stop
						i2c_cnt <= 0;
					end
				end
				else if(i2c_ack) begin
					if(~i2c_rw) begin
						if(i2c_disp) begin
							if(i2c_bcnt == 1) i2c_dispdata <= (i2c_tmp[7:6] == 2'b01);
							else if(i2c_dispdata) lcd_data[i2c_bcnt[9:0] - 10'd2] <= i2c_tmp;
						end
						else begin
							if(i2c_bcnt == 1) mt32_mode <= i2c_tmp;
							if(i2c_bcnt == 2) mt32_rom  <= i2c_tmp;
							if(i2c_bcnt == 3) mt32_sf   <= i2c_tmp;
							if(i2c_bcnt == 3) mt32_newmode <= ~mt32_newmode;
						end
					end
					if(~&i2c_bcnt) i2c_bcnt <= i2c_bcnt + 1'd1;
					sda_out <= 0;
					i2c_cnt <= 10;
				end
			end
			else if(i2c_rw && i2c_ack && (i2c_cnt != 0) && ~i2c_disp) begin
				if(i2c_bcnt == 1) sda_out <= mode_req[i2c_cnt[2:0] - 2'd2];
				if(i2c_bcnt == 2) sda_out <= rom_req[i2c_cnt[2:0] - 2'd2];
				if(i2c_bcnt == 3) sda_out <= mt32_sf_req[i2c_cnt[2:0] - 2'd2];
				if(i2c_bcnt == 3) reset_r <= 0;
			end
		end
	end

	if(reset) begin
		reset_r <= 1;
		mt32_available <= 0;
		mt32_mode <= 0;
		mt32_rom <= 0;
		mt32_sf <= 0;
		mt32_newmode <= 0;
		mt32_lcd_update <= 0;
		sda_out <= 1;
		i2c_cnt <= 0;
		i2c_bcnt <= 0;
		i2c_ack <= 0;
		i2c_rw <= 0;
		i2c_disp <= 0;
		i2c_dispdata <= 0;
	end
end

reg       video_old_de = 0;
reg       video_old_vs = 0;
reg [7:0] video_hcnt = 0;
reg [6:0] video_vcnt = 0;
reg [7:0] video_de_shift = 0;
always @(posedge CLK_VIDEO) begin
	if(CE_PIXEL) begin
		video_old_de <= VGA_DE;
		video_old_vs <= VGA_VS;

		if(~&video_hcnt) video_hcnt <= video_hcnt + 1'd1;
		video_de_shift <= (video_de_shift << 1) | {7'd0, (~video_old_de & VGA_DE)};
		if(video_de_shift[7]) video_hcnt <= 0;

		if(video_old_de & ~VGA_DE & ~&video_vcnt) video_vcnt <= video_vcnt + 1'd1;
		if(~video_old_vs & VGA_VS) video_vcnt <= 0;

		mt32_lcd_en  <= mt32_available & ~video_hcnt[7] &&
		                (lcd_sz ? ~video_vcnt[6] : (video_vcnt[6:5] == 2'b00));
		mt32_lcd_pix <= lcd_data[{video_vcnt[5:3],video_hcnt[6:0]}][video_vcnt[2:0]];
	end

	if(reset) begin
		video_old_de <= 0;
		video_old_vs <= 0;
		video_hcnt <= 0;
		video_vcnt <= 0;
		video_de_shift <= 0;
		mt32_lcd_en <= 0;
		mt32_lcd_pix <= 0;
	end
end

endmodule
