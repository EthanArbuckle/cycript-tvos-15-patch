//
//  dylib_unpacker.m
//  cycript-patcher
//
//  Created by Ethan Arbuckle on 1/22/25.
//

#include <Foundation/Foundation.h>
#include <mach-o/loader.h>
#include <mach/error.h>
#include <mach/mach.h>
#include <fcntl.h>
#include <mach-o/getsect.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>

static const struct section_64 *get_section_for_current_arch(const char *segname, const char *sectname) {
    uint32_t bufsize = 1024;
    char path[bufsize];
    if (_NSGetExecutablePath(path, &bufsize) != 0) {
        return NULL;
    }
    
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return NULL;
    }
    
    struct mach_header_64 mh;
    lseek(fd, 0, SEEK_SET);
    if (read(fd, &mh, sizeof(mh)) != sizeof(mh)) {
        close(fd);
        return NULL;
    }
    
    uint8_t load_commands[mh.sizeofcmds];
    read(fd, load_commands, mh.sizeofcmds);
    
    struct section_64 *target_section = NULL;
    struct load_command *lc = (struct load_command *)load_commands;
    for (uint32_t i = 0; i < mh.ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)lc;
            if (strcmp(seg->segname, segname) == 0) {
                struct section_64 *sect = (struct section_64 *)((uint8_t *)seg + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    if (strcmp(sect[j].sectname, sectname) == 0) {
                        
                        target_section = malloc(sizeof(struct section_64));
                        memcpy(target_section, &sect[j], sizeof(struct section_64));
                        
                        lseek(fd, target_section->offset, SEEK_SET);
                        void *section_data = malloc(target_section->size);
                        read(fd, section_data, target_section->size);
                        target_section->addr = (uint64_t)section_data;
                        
                        break;
                    }
                }
            }
        }
        lc = (struct load_command *)((uint8_t *)lc + lc->cmdsize);
    }
    
    close(fd);
    return target_section;
}

kern_return_t unpack_dylib_to_path(const char *path) {
    const struct section_64 *sect = get_section_for_current_arch("__CONST", "__server_dylib");
    if (sect == NULL) {
        printf("Failed to find section\n");
        return KERN_FAILURE;
    }
    
    unlink(path);
    int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0) {
        perror("open failed");
        free((void*)sect);
        return KERN_FAILURE;
    }
    
    void *data_addr = (void *)sect->addr;
    
    size_t remaining = sect->size;
    uint8_t *current = data_addr;
    while (remaining > 0) {
        ssize_t written = write(fd, current, remaining);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("write failed");
            close(fd);
            free((void *)sect);
            return KERN_FAILURE;
        }
        remaining -= written;
        current += written;
    }
    
    if (fchmod(fd, 0777) < 0) {
        perror("chmod failed");
    }
    
    if (fchown(fd, 501, 501) < 0) {
        perror("chown failed");
    }
    
    close(fd);
    free((void *)sect);
    return KERN_SUCCESS;
}
