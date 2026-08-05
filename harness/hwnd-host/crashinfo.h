// Print a symbolized stack (and write crash.dmp) when the process faults.
// Call once at startup, before anything else can crash.
#pragma once

void crashinfo_install(void);
