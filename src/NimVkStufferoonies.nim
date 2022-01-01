import nimgl/[glfw, vulkan]
from bitops import testBit

proc keyEventCallback(window: GLFWWindow, key, scancode, action, mods: int32) {.cdecl.} =
  if action == GLFWPress:
    if key == GLFWKey.ESCAPE:
      window.setWindowShouldClose(true)


template vkCheck(result: VkResult): untyped =
  assert result == VK_SUCCESS


template isNullHandle(handle: untyped): bool =
  VkHandle(handle) == VkHandle(0)


type
  VulkanState = object
    window    : GLFWWindow
    device    : VkDevice
    instance  : VkInstance
    surface   : VkSurfaceKHR
    physDev   : VkPhysicalDevice
    queue     : VkQueue # Graphics and present on the same queue for now
    cmdPool   : VkCommandPool
    swapchain : VkSwapchainKHR

# My global renderer state variable. Could arguably choose a better name -- in
# Intel's "API Without Secrets" tutorial they just use the name "Vulkan". So
# this doesn't seem too bad.
var Vk : VulkanState

proc initVulkan(): bool =
  # I usually get these names via macros like VK_KHR_SWAPCHAIN_EXTENSION_NAME
  # in C++ but those don't seem to be defined in nimgl. So I'm just running
  # 'vulkaninfo' on my local machine and putting the strings from that in here.

  assert glfwVulkanSupported()

  var
    requiredInstanceExtensions = @[ "VK_EXT_debug_utils" ]
    requiredLayers             = @[ "VK_LAYER_KHRONOS_validation" ]

    numGlfwInstanceExtensions : uint32 = 0

  let
    glfwInstanceExtensions    : cstringArray
      = glfwGetRequiredInstanceExtensions(addr numGlfwInstanceExtensions)

  for i in 0 .. numGlfwInstanceExtensions:
    let ext = $glfwInstanceExtensions[i]
    echo "GLFW requires extension: ", ext
    requiredInstanceExtensions.add ext

  deallocCStringArray glfwInstanceExtensions

  let
    appInfo = VkApplicationInfo(
      sType            : VK_STRUCTURE_TYPE_APPLICATION_INFO,
      pApplicationName : "EEEEEE",
      apiVersion       : vkMakeVersion(1, 1, 0)
    )

    createInfo = VkInstanceCreateInfo(
      sType                   : VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      pApplicationInfo        : unsafeAddr appInfo,
      enabledExtensionCount   : cast[uint32](requiredInstanceExtensions.len),
      ppEnabledExtensionNames : allocCStringArray(requiredInstanceExtensions),
      enabledLayerCount       : cast[uint32](requiredLayers.len),
      ppEnabledLayerNames     : allocCStringArray(requiredLayers)
      # The 'allocCStringArray' calls in here are leaks. But I don't care :)
    )

  vkCheck vkCreateInstance(unsafeAddr createInfo, nil, addr Vk.instance)

  echo "Instance created ok"

  Vk.window  = glfwCreateWindow(1920, 1080, cstring("Hello"))
  vkCheck glfwCreateWindowSurface(Vk.instance, Vk.window, nil, addr Vk.surface)

  var
    physicalDevices    : seq[VkPhysicalDevice]
    numPhysicalDevices : uint32 = 0

  vkCheck vkEnumeratePhysicalDevices(Vk.instance, addr numPhysicalDevices, nil)
  physicalDevices.setLen numPhysicalDevices
  vkCheck vkEnumeratePhysicalDevices(Vk.instance, addr numPhysicalDevices, addr physicalDevices[0])

  const requiredDeviceExtensions = @[ "VK_KHR_swapchain", "VK_KHR_maintenance1" ]

  block selectPhysicalDevice:
    for dev in physicalDevices:
      for ext in requiredDeviceExtensions:
        var
          props: VkPhysicalDeviceProperties
          feats: VkPhysicalDeviceFeatures

        vkGetPhysicalDeviceProperties(dev, addr props)
        vkGetPhysicalDeviceFeatures(dev, addr feats)

        # Probably all I care about... I reckon I'll use 1.2.182 or whatever the
        # latest stable release is.
        if vkVersionMajor(props.apiVersion) < 1: continue

        # Passed all checks, use this one
        Vk.physDev = dev
        break selectPhysicalDevice

  assert not Vk.physDev.isNullHandle

  var queueFamilyIdx: uint32 = high(uint32)

  block selectQueueFamily:
    var numQueueFamilies: uint32
    vkGetPhysicalDeviceQueueFamilyProperties(
      Vk.physDev, addr numQueueFamilies, nil)
    assert numQueueFamilies > 0

    var queueFamilyProps: seq[VkQueueFamilyProperties]
    queueFamilyProps.setLen numQueueFamilies
    vkGetPhysicalDeviceQueueFamilyProperties(
      Vk.physDev, addr numQueueFamilies, addr queueFamilyProps[0])

    for i in 0 .. numQueueFamilies:
      let props = queueFamilyProps[i]
      if testBit(uint32(props.queueFlags), uint32(VK_QUEUE_GRAPHICS_BIT)) and props.queueCount > 0:
        queueFamilyIdx = i
        break selectQueueFamily

  assert queueFamilyIdx != high(uint32)

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

  let vulkanInitOk = initVulkan()
  assert vulkanInitOk


when isMainModule:
  main()
