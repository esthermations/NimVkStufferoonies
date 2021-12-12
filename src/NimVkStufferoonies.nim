import nimgl/[glfw, vulkan]

proc keyEventCallback(window: GLFWWindow, key, scancode, action, mods: int32) {.cdecl.} =
  if action == GLFWPress:
    if key == GLFWKey.ESCAPE:
      window.setWindowShouldClose(true)

type
  VulkanState = object
    device   : VkDevice
    instance : VkInstance
    surface  : VkSurfaceKHR
    physDev  : VkPhysicalDevice
    queue    : VkQueue # Graphics and present on the same queue for now
    cmdPool  : VkCommandPool

var
  gVulkanState : VulkanState

proc initVulkan(): bool =
  # I usually get these names via macros like VK_KHR_SWAPCHAIN_EXTENSION_NAME
  # in C++ but those don't seem to be defined in nimgl. So I'm just running
  # 'vulkaninfo' on my local machine and putting the strings from that in here.

  var
    requiredDeviceExtensions   = [ "VK_KHR_swapchain", "VK_KHR_maintenance1" ]

  let
    requiredInstanceExtensions = [ "VK_EXT_debug_utils" ]

    appInfo = VkApplicationInfo(
      sType            : VK_STRUCTURE_TYPE_APPLICATION_INFO,
      pApplicationName : "EEEEEE",
      apiVersion       : vkMakeVersion(1, 1, 0)
    )

    createInfo = VkInstanceCreateInfo(
      sType                   : VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      pApplicationInfo        : unsafeAddr appInfo,
      enabledExtensionCount   : cast[uint32](requiredInstanceExtensions.len),
      ppEnabledExtensionNames : unsafeAddr requiredInstanceExtensions
    )

  var errors: VkResult = VK_SUCCESS

  errors = vkCreateInstance(addr createInfo, nil, addr gVulkanState.instance)



  # TODO
  false


proc main() =
  assert glfwInit()

  glfwWindowHint(GlfwContextVersionMajor, 3)
  glfwWindowHint(GlfwContextVersionMinor, 3)
  glfwWindowHint(GlfwResizable, GLFW_FALSE)

  let w: GLFWWindow = glfwCreateWindow(1280, 720, "EEEEEE")
  if w == nil: quit(-1)

  discard w.setKeyCallback(keyEventCallback)
  w.makeContextCurrent()

  assert initVulkan()


when isMainModule:
  main()
