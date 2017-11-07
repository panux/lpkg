#include<stdio.h>
#include<stdlib.h>
#include<ctype.h>

int main(int argc, char** argv) {
    if(argc != 3) {
        printf("Usage: %s ver1 ver2\n", *argv);
        return 1;
    }
    char* a = argv[1];
    char* b = argv[2];
    while(*a && *b) {
        if(!isdigit(*a)) {
            a++;
        } else if(!isdigit(*b)) {
            b++;
        } else {
            unsigned long x = strtoul(a, &a, 10);
            unsigned long y = strtoul(b, &b, 10);
            if(x > y) {
                return 0;
            } else if(x < y) {
                return 1;
            }
        }
    }
    while(*a) { //if a has another part
        if(isdigit(*a)) {
            return 0;
        }
        a++;
    }
    return 1;
}
