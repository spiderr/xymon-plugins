/*
 * openmanage-pd-sense — MegaRAID passthrough REQUEST SENSE / READ CAPACITY
 *
 * Used by openmanage.sh to detect SCSI FORMAT UNIT in progress (not visible
 * via perccli show initialization/erase).
 *
 * Usage: openmanage-pd-sense <block_device> <megaraid_target_id>
 * Output (one line):
 *   FORMAT_IN_PROGRESS <percent>
 *   OK [capacity_bytes=<n>]
 *   BUSY
 *   ERROR <message>
 *
 * Based on MegaRAID IOCTL layout from smartmontools / megaraid_format_tools.
 * Run as root (or via sudo -n from xymon).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/ioctl.h>
#include <sys/uio.h>
#include <scsi/sg.h>

#define SCSI_IOCTL_GET_BUS_NUMBER 0x5386
#define u8  uint8_t
#define u16 uint16_t
#define u32 uint32_t
#define MEGASAS_MAGIC        'M'
#define MEGASAS_IOC_FIRMWARE _IOWR(MEGASAS_MAGIC, 1, struct megasas_iocpacket)
#define MFI_CMD_PD_SCSI_IO   0x04
#define MFI_FRAME_DIR_READ   0x0010
#define MAX_IOCTL_SGE        16

struct megasas_sge32 {
	u32 phys_addr;
	u32 length;
} __attribute__((packed));

union megasas_sgl {
	struct megasas_sge32 sge32[1];
} __attribute__((packed));

struct megasas_pthru_frame {
	u8 cmd;
	u8 sense_len;
	u8 cmd_status;
	u8 scsi_status;
	u8 target_id;
	u8 lun;
	u8 cdb_len;
	u8 sge_count;
	u32 context;
	u32 pad_0;
	u16 flags;
	u16 timeout;
	u32 data_xfer_len;
	u32 sense_buf_phys_addr_lo;
	u32 sense_buf_phys_addr_hi;
	u8 cdb[16];
	union megasas_sgl sgl;
} __attribute__((packed));

struct megasas_iocpacket {
	u16 host_no;
	u16 __pad1;
	u32 sgl_off;
	u32 sge_count;
	u32 sense_off;
	u32 sense_len;
	union {
		u8 raw[128];
		struct megasas_pthru_frame pthru;
	} frame;
	struct iovec sgl[MAX_IOCTL_SGE];
} __attribute__((packed));

static int send_cmd(int fd, int bus, int target, u8 *cdb, int cdblen,
		    void *data, int len)
{
	struct megasas_iocpacket ioc;
	struct megasas_pthru_frame *pthru = &ioc.frame.pthru;

	memset(&ioc, 0, sizeof(ioc));
	ioc.host_no = bus;
	if (len > 0 && data) {
		ioc.sge_count = 1;
		ioc.sgl_off = offsetof(struct megasas_pthru_frame, sgl);
		ioc.sgl[0].iov_base = data;
		ioc.sgl[0].iov_len = len;
		pthru->sge_count = 1;
		pthru->data_xfer_len = len;
		pthru->sgl.sge32[0].phys_addr = (u32)(uintptr_t)data;
		pthru->sgl.sge32[0].length = len;
	}
	pthru->cmd = MFI_CMD_PD_SCSI_IO;
	pthru->cmd_status = 0xFF;
	pthru->target_id = (u8)target;
	pthru->cdb_len = (u8)cdblen;
	pthru->flags = MFI_FRAME_DIR_READ;
	memcpy(pthru->cdb, cdb, (size_t)cdblen);
	if (ioctl(fd, MEGASAS_IOC_FIRMWARE, &ioc) != 0)
		return -1;
	return pthru->cmd_status;
}

int main(int argc, char **argv)
{
	int fd_dev, fd_mega, bus_no, target, st;
	u8 sense[32];
	u8 cap[8];
	u8 sense_cdb[6] = { 0x03, 0, 0, 0, 18, 0 };
	u8 rc_cdb[10] = { 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	u8 key, asc, ascq;
	unsigned prog;
	int pct;

	if (argc < 3) {
		fprintf(stderr, "Usage: %s <block_device> <megaraid_target_id>\n",
			argv[0]);
		return 2;
	}
	target = atoi(argv[2]);
	if (target < 0 || target > 255) {
		printf("ERROR invalid_target\n");
		return 2;
	}

	fd_dev = open(argv[1], O_RDWR | O_NONBLOCK);
	if (fd_dev < 0) {
		printf("ERROR open_device errno=%d\n", errno);
		return 1;
	}
	if (ioctl(fd_dev, SCSI_IOCTL_GET_BUS_NUMBER, &bus_no) != 0) {
		printf("ERROR bus_number errno=%d\n", errno);
		close(fd_dev);
		return 1;
	}
	close(fd_dev);

	fd_mega = open("/dev/megaraid_sas_ioctl_node", O_RDWR);
	if (fd_mega < 0) {
		printf("ERROR open_megaraid errno=%d\n", errno);
		return 1;
	}

	memset(sense, 0, sizeof(sense));
	st = send_cmd(fd_mega, bus_no, target, sense_cdb, 6, sense, 18);
	if (st < 0) {
		printf("ERROR sense_ioctl\n");
		close(fd_mega);
		return 1;
	}

	key = (u8)(sense[2] & 0x0f);
	asc = sense[12];
	ascq = sense[13];

	/* NOT READY / FORMAT IN PROGRESS */
	if (key == 0x02 && asc == 0x04 && ascq == 0x04) {
		pct = -1;
		if (sense[15] & 0x80) {
			prog = ((unsigned)sense[16] << 8) | (unsigned)sense[17];
			pct = (int)((prog * 100u) / 65536u);
			if (pct > 99)
				pct = 99; /* 100 only when complete */
		}
		if (pct >= 0)
			printf("FORMAT_IN_PROGRESS %d\n", pct);
		else
			printf("FORMAT_IN_PROGRESS unknown\n");
		close(fd_mega);
		return 0;
	}

	/* Other not-ready */
	if (key == 0x02) {
		printf("BUSY key=%02x asc=%02x ascq=%02x\n", key, asc, ascq);
		close(fd_mega);
		return 0;
	}

	memset(cap, 0, sizeof(cap));
	st = send_cmd(fd_mega, bus_no, target, rc_cdb, 10, cap, 8);
	if (st == 0) {
		uint64_t max_lba = ((uint64_t)cap[0] << 24) | ((uint64_t)cap[1] << 16) |
				   ((uint64_t)cap[2] << 8) | (uint64_t)cap[3];
		uint32_t bs = ((uint32_t)cap[4] << 24) | ((uint32_t)cap[5] << 16) |
			      ((uint32_t)cap[6] << 8) | (uint32_t)cap[7];
		uint64_t bytes = (max_lba + 1) * (uint64_t)bs;
		printf("OK capacity_bytes=%llu block_size=%u\n",
		       (unsigned long long)bytes, bs);
	} else {
		printf("OK\n");
	}
	close(fd_mega);
	return 0;
}
