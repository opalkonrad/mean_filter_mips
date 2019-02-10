.eqv BUFFSPACE 200000		# buffers space

.data
inputFileMsg:			.asciiz	"Mean Filter (.bmp)\nEnter input filename: "
headerBmp: 				.space 54
inputFilename:		.space 64
inputFileBuff:		.space BUFFSPACE

outputFileMsg:		.asciiz "Enter output filename: "
outputFilename:		.space 64
outputFileBuff:		.space BUFFSPACE

maskMsg:					.asciiz "Enter mask size (e.g. 3, 5, 7, ...): "
maskErrMsg:				.asciiz "Mask is too big comparing to the image and program's capabilities, try one more time!\n"
maskErrMsgSmall:	.asciiz "Mask is too small, try one more time!\n"
maskErrMsgEven:		.asciiz "Mask can't be an even number, try one more time!\n"

fileErrMsg:				.asciiz "No file in the folder, try one more time!\n"
bppErrMsg:				.asciiz "Only files with 24 bits per pixel, try one more time!\n"

.text
main:
	# print input file message
	la	$a0, inputFileMsg
	li	$v0, 4
	syscall
	
	# get input filename from user
	la	$a0, inputFilename
	li	$a1, 64
	li	$v0, 8
	syscall
	
	# print output file message
	la	$a0, outputFileMsg
	li	$v0, 4
	syscall
	
	# get output filename from user
	la	$a0, outputFilename
	li	$a1, 64
	li	$v0, 8
	syscall
	
	# print mask size message
	la	$a0, maskMsg
	li	$v0, 4
	syscall
	
	# get mask size from user
	li	$v0, 5
	syscall
	move	$s0, $v0							# put mask size in $s0
	bltu	$s0, 3, _maskErrSmall	# mask too small
	andi	$t0, $s0, 1
	beq	$t0, 0, _maskErrEven		# mask is an even number

		
#--------------- replace '\n' with '0' in filenames ---------------#

	la	$t0, inputFilename			# pointer to inputFile
	li	$t3, 0									# loop counter (0 - working on inputFile, 1 - working on outputFile, 2 - endLoop)
_loop:
	li	$t1, 0									# loopZero counter (counting every digit)

_loopZero:
	lbu	$t2, ($t0)							# load byte
	addiu	$t1, $t1, 1						# increase loopZero counter
	beq	$t2, '\n', _addZero			# if loaded byte is '\n' then addZero
	beq	$t1, 32, _addZero				# if end of buff then addZero
	addiu	$t0, $t0, 1						# increase pointer to input/outputFile
	j	_loopZero
	
_addZero:
	li	$t2, 0									# put '0' in $t2
	sb	$t2, ($t0)							# overwrite '\n' with '0'
	addiu	$t3, $t3, 1						# increase loop counter
	beq	$t3, 2, _inputFileOpen	# input/outputFiles overwrite check
	la	$t0, outputFilename			# pointer to outputFile
	j	_loop


#--------------- tasks related to buffers ---------------#
	
_inputFileOpen:
	# open input file
	la	$a0, inputFilename
	li	$a1, 0									# read flag
	li	$a2, 0									# ignore mode
	li	$v0, 13
	syscall
	bltz	$v0, _fileErr					# no file in the folder
	move	$s6, $v0							# file descriptor (input)
	
	# save header data in header info buffer
	move	$a0, $s6							# file descriptor (input)
	la	$a1, headerBmp					# address to store header info
	li	$a2, 54									# max 54 characters
	li	$v0, 14
	syscall
	
	# save information about image
	lw	$s1, headerBmp+18				# width
	lw	$s2, headerBmp+22				# height
	lw	$s3, headerBmp+34				# size of data section
	lb	$t0, headerBmp+28				# number of bits per pixel

	# other things connected to input image
	bne	$t0, 24, _bppErr				# 24 bits per pixel only
	mulu	$s1, $s1, 3						# working on colors not pixels

	# count padding
	divu	$t0, $s1, 4
	mfhi	$t0										# the rest from dividing
	li	$t1, 4
	subu	$s4, $t1, $t0					# padding to add
	bne	$s4, 4, _keepGoing
	li	$s4, 0									# no padding to add
	
_keepGoing:			
	# check if the [(width + padding) * mask] is not too big for the inputFileBuff
	addu	$t0, $s1, $s4					# width + padding
	mul	$t1, $t0, $s0						# mask * (width + padding)
	bgtu	$t1, BUFFSPACE, _maskErr	# the result needs more space than program can give
	
	# open output file
	la	$a0, outputFilename
	li	$a1, 1									# read flag
	li	$a2, 0									# ignore mode
	li	$v0, 13
	syscall
	move	$s7, $v0							# file descriptor (output)
	
	# write headerBmp to output file
	move	$a0, $s7							# file descriptor (output)
	la	$a1, headerBmp					# address of header info
	li	$a2, 54									# max 54 characters
	li	$v0, 15
	syscall
	
	addiu	$sp, $sp, -8
	sw	$s6, 0($sp)							# save input file descriptor to the stack
	sw	$s7, 4($sp)							# save output file descriptor to the stack
	
	
#--------------- start of filtering ---------------#

#	$s0 - (mask/2)*3
#	$s1 - (width*3)-1
#	$s2 - height-1
#	$s3 - size of data section / width+padding
#	$s4 - padding
#	$s5 - (mask/2)
#	$s6 - descriptor input / (width*3)-(mask*3)
#	$s7 - descriptor output / mask^2
#	$t0 - tmp pointer
#	$t1 - pointer input
#	$t2 - pointer output
#	$t3 - number of lines to read then decreased by mask
#	$t4 - number of bytes to read / (width*3)+padding
#	$t5 - actual color in line
#	$t6 - number of processed lines in buffer
#	$t7 - line altogether
#	$t8 - tmp
#	$t9 - sum of numbers
#	$a3 - height-1-(mask/2)

	la	$t1, inputFileBuff			# pointer to inputFileBuff
	la 	$t2, outputFileBuff			# pointer to outputFileBuff
	
	bgtu	$s3, BUFFSPACE, _bigImg		# image is greater than buffer -> _bigImg
	move	$t4, $s3							# number of bytes to read
	move	$t3, $s2							# number of lines to read
	j	_preparation
	
_bigImg:
	addu	$s3, $s1, $s4					# width of line + padding
	li	$t0, BUFFSPACE
	divu	$t3, $t0, $s3					# numbers of lines to read
	mulu	$t4, $t3, $s3					# max bytes to read
	
_preparation:
	addiu	$s1, $s1, -1					# count digits starting from 0
	addiu	$s2, $s2, -1					# count lines starting from 0
	move	$s5, $s0
	mulu	$s7, $s5, $s5					# mask^2
	srl	$s5, $s5, 1							# mask/2
	mulu	$s0, $s5, 3						# (mask/2)*3
	subu	$s6, $s1, $s0					# width - ((mask/2)*3) starting from 0
	
	li	$t7, 0									# counter line altogether
	li	$t9, 0									# sum of colors
	
	move	$a3, $s2
	subu	$a3, $a3, $s5					# height - 1 - mask/2
	
_filterReady:
	# read some part of inputFile to inputFileBuff
	lw	$t5, 0($sp)
	move	$a0, $t5							# file descriptor (input)
	move	$a1, $t1							# address of buffer
	move	$a2, $t4							# max number of bytes
	li	$v0, 14
	syscall
	
	li	$t5, 0									# counter of digits
	li	$t6, 0									# counter of lines in buffer
	li	$a2, 0									# counter of bytes to write to file
	
	lw	$t4, headerBmp+18
	mulu	$t4, $t4, 3
	addu	$t4, $t4, $s4					# width*3 + padding
	
	bne	$t7, 0, _additionalAfterWrite
	
	# number of lines that can be processed in first read
	subu	$t3, $t3, $s5					# without upper lines (under mask)
	subu	$t3, $t3, $s5					# without lower lines (under mask)
	j	_filter
	
_additionalAfterWrite:
	mulu	$t8, $s3, $s5					# mask * (width + padding)	
	subu	$t1, $t1, $t8					# start processing the proper line

_filter:
	bltu	$t7, $s5, _rewriteLine		# rewrite lines (under mask)
	bgtu	$t7, $a3, _rewriteLine
	beq	$t6, $t3, _filterGetReady		# write outputFileBuff to output file and read next digits from input file
	bltu	$t5, $s0, _rewriteDigitsUnderMask		# rewrite digits (under mask)
	bgtu	$t5, $s6, _rewriteDigitsUnderMask

	move	$t0, $t1							# floating pointer to inputFileBuff
	addu	$a0, $t0, $s0					# right end under mask

	mulu	$t9, $t4, $s5
	addu	$a1, $t0, $t9
	addu	$a1, $a1, $s0					# top right edge under mask
	subu	$a0, $a0, $t9					# bottom right edge under mask
	subu	$t0, $t0, $t9
	subu	$t0, $t0, $s0					# bottom left edge under mask

	li	$t9, 0									# sum of colors

_loopX:
	lb	$t8, ($t0)
	sll	$t8, $t8, 24
	srl	$t8, $t8, 24
	addu	$t9, $t9, $t8
	beq	$t0, $a0, _loopY
	addiu	$t0, $t0, 3						# next color under mask
	j	_loopX

_loopY:
	addu	$t0, $t0, $t4					# next line under mask
	bgtu	$t0, $a1, _loopEnd		# sum of colors under mask ready
	subu	$t0, $t0, $s0
	subu	$t0, $t0, $s0					# move to the most left color under mask
	addu	$a0, $a0, $t4					# right edge under mask
	j	_loopX

_loopEnd:
	divu	$t9, $t9, $s7					# divide by mask^2
	sb		$t9, ($t2)
	addiu	$t1, $t1, 1						# next digit (input)
	addiu	$t2, $t2, 1						# next digit (output)
	addiu	$t5, $t5, 1						# next digit (counter)
	addiu	$a2, $a2, 1						# increase number of bytes to write to file
	j	_filter

_rewriteLine:
	addiu	$a2, $a2, 1						# increase number of bytes to write to file
	lb	$t8, ($t1)
	sll	$t8, $t8, 24						# remove everything except color
	srl	$t8, $t8, 25						# just to make pixels under mask not so catchy
	sb	$t8, ($t2)
	beq	$t5, $s1, _paddingNoNextLine		# don't increase line counter ($t6)
	addiu	$t1, $t1, 1
	addiu	$t2, $t2, 1
	addiu	$t5, $t5, 1
	j	_rewriteLine

_rewriteDigitsUnderMask:
	addiu	$a2, $a2, 1						# increase number of bytes to write to file
	lb	$t8, ($t1)
	sll	$t8, $t8, 24						# remove everything except color
	srl	$t8, $t8, 25						# just to make pixels under mask not so catchy
	sb	$t8, ($t2)
	beq	$t5, $s1, _padding
	addiu	$t1, $t1, 1
	addiu	$t2, $t2, 1
	addiu	$t5, $t5, 1
	j	_filter	

_padding:
	addiu	$t6, $t6, 1						# next line
	
_paddingNoNextLine:
	beq	$s4, 0, _noPadding
	addu	$t1, $t1, $s4					# adding padding
	addu	$t2, $t2, $s4
	addu	$a2, $a2, $s4
		
_noPadding:
	li	$t5, 0									# first digit of new line
	beq	$t7, $s2, _filterGetReady		# last line (the most upper one) -> write to file
	addiu	$t7, $t7, 1						# next line altogether
	addiu	$t1, $t1, 1
	addiu	$t2, $t2, 1
	j	_filter

_filterGetReady:
	# write to output file
	lw	$t5, 4($sp)							# get output file descriptor from stack
	move 	$a0, $t5
	la	$a1, outputFileBuff
	li	$v0, 15
	syscall

	beq	$t7, $s2, _terminate		# terminate, image processed

	la	$t2, outputFileBuff			# reset pointer

	mulu	$s2, $s3, $s5					# bytes to move the pointer to start rewriting
	subu	$t1, $t1, $s2					# pointer set to the beginnig of lines to rewrite
	sll	$t8, $s2, 1							# bytes to rewrite

	li	$t0, BUFFSPACE
	subu	$t0, $t0, $t8					# free space in input buffer
	divu	$t0, $t0, $s3					# numbers of lines to read
	mulu	$t4, $t0, $s3					# max bytes to read

	la	$t9, inputFileBuff			# tmp pointer to inputFileBuff

_rewriteBeforeRead:
	# rewrite not processed colors to the beginning of inputFileBuffer
	lb	$t3, ($t1)
	sll	$t3, $t3, 24
	srl	$t3, $t3, 24
	sb	$t3, ($t9)
	addiu	$t1, $t1, 1
	addiu	$t9, $t9, 1
	addiu	$t8, $t8, -1
	bne	$t8, 0, _rewriteBeforeRead

	move	$t1, $t9							# change pointers
	move	$t3, $t0							# find how many lines can be processed

	lw	$s2, headerBmp+22				# height
	addiu	$s2, $s2, -1					# count lines starting from 0

	j	_filterReady


#--------------- terminate program ---------------#

_terminate:
	# clear stack
	addiu	$sp, $sp, 8

	# close input file
	move	$a0, $s6
	li	$v0, 16
	syscall

	# close output file
	move	$a0, $s7
	li	$v0, 16
	syscall

	li	$v0, 10
	syscall


#--------------- error handlers ---------------#

_fileErr:
	# print file error message
	la	$a0, fileErrMsg
	li	$v0, 4
	syscall
	j	main

_maskErr:
	# print mask error message
	la	$a0, maskErrMsg
	li	$v0, 4
	syscall
	j	main
	
_maskErrSmall:
	# print mask error message (small)
	la	$a0, maskErrMsgSmall
	li	$v0, 4
	syscall
	j	main
	
_maskErrEven:
	# print mask error message (even)
	la	$a0, maskErrMsgEven
	li	$v0, 4
	syscall
	j	main
	
_bppErr:
	# print bits per pixel message
	la	$a0, bppErrMsg
	li	$v0, 4
	syscall
	j	main