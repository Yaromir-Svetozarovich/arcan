PROJECT( arcan_cfgfs )
cmake_minimum_required(VERSION 2.8.0 FATAL_ERROR)
set(CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../../platform/cmake/modules)

if (CMAKE_BUILD_TYPE STREQUAL "Debug")
	add_definitions(-D_DEBUG)
endif()

find_package(arcan_shmif REQUIRED)
pkg_check_modules(FUSE3 REQUIRED fuse3)
find_package(Math REQUIRED)
find_package(RT REQUIRED)
find_package(Threads REQUIRED)
find_package(DL REQUIRED)

add_definitions(
	-Wall
	-D__UNIX
	-DPOSIX_C_SOURCE
	-DGNU_SOURCE
	-Wno-unused-function
	-std=gnu11 # shmif-api requires this
)

SET(LIBRARIES
	Threads::Threads
	Math::Math
	RT::RT
	DL::DL
	${ARCAN_SHMIF_LIBRARY}
	${FUSE3_LINK_LIBRARIES}
)

set(SOURCES
	acfgfs.c
)

add_executable(${PROJECT_NAME} ${SOURCES})
target_link_libraries(${PROJECT_NAME} ${LIBRARIES})
install(TARGETS ${PROJECT_NAME} DESTINATION bin)
target_include_directories(${PROJECT_NAME} PUBLIC ${ARCAN_SHMIF_INCLUDE_DIR} ${FUSE3_INCLUDE_DIRS})

if (CMAKE_SYSTEM_NAME MATCHES "(FreeBSD|NetBSD|OpenBSD)")
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/arcan_cfgfs.1 DESTINATION man/man1)
else()
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/arcan_cfgfs.1 DESTINATION share/man/man1)
endif()
