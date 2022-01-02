import nimgl/[glfw, vulkan]
from bitops import bitand

proc keyEventCallback(window: GLFWWindow, key, scancode, action, mods: int32) {.cdecl.} =
  if action == GLFWPress:
    if key == GLFWKey.ESCAPE:
      window.setWindowShouldClose(true)


template vkCheck(result: VkResult): untyped =
  doAssert result == VK_SUCCESS


template vkHasBits(value, mask: untyped): bool =
  bitand(uint32(value), uint32(mask)) == uint32(value)


template isNullHandle(handle: untyped): bool =
  VkHandle(handle) == VkHandle(0)


type
  VulkanState = object
    window    : GLFWWindow
    device    : VkDevice
    instance  : VkInstance
    surface   : VkSurfaceKHR
    physDev   : VkPhysicalDevice
    queueIdx  : uint32
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
  vkCheck vkEnumeratePhysicalDevices(
    Vk.instance, addr numPhysicalDevices, addr physicalDevices[0])

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
  echo "Got physical device"

  block selectQueueFamily:
    Vk.queueIdx = high(uint32)

    var numQueueFamilies: uint32
    vkGetPhysicalDeviceQueueFamilyProperties(
      Vk.physDev, addr numQueueFamilies, nil)
    assert numQueueFamilies > 0

    var queueFamilyProps: seq[VkQueueFamilyProperties]
    queueFamilyProps.setLen numQueueFamilies
    vkGetPhysicalDeviceQueueFamilyProperties(
      Vk.physDev, addr numQueueFamilies, addr queueFamilyProps[0])

    for i in 0 .. numQueueFamilies:
      let
        props              = queueFamilyProps[i]
        hasQueuesAvailable = props.queueCount > 0
        hasGraphicsQueue   = vkHasBits(props.queueFlags, VK_QUEUE_GRAPHICS_BIT)

      if hasQueuesAvailable and hasGraphicsQueue:
        Vk.queueIdx = i
        break selectQueueFamily

  assert Vk.queueIdx != high(uint32)
  echo "Using queue family id ", $Vk.queueIdx

  block createQueue:
    let
      queuePriorities : array[1, float32] = [ 1.0f ]
      queueCreateInfo = VkDeviceQueueCreateInfo(
        sType            : VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        pNext            : nil,
        flags            : VkDeviceQueueCreateFlags(0),
        queueFamilyIndex : Vk.queueIdx,
        queueCount       : uint32(queuePriorities.len),
        pQueuePriorities : unsafeAddr queuePriorities[0]
      )

      deviceCreateInfo = VkDeviceCreateInfo(
        sType                   : VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        pNext                   : nil,
        flags                   : VkDeviceCreateFlags(0),
        queueCreateInfoCount    : 1,
        pQueueCreateInfos       : unsafeAddr queueCreateInfo,
        enabledLayerCount       : 0,
        ppEnabledLayerNames     : nil,
        enabledExtensionCount   : 0,
        ppEnabledExtensionNames : nil,
        pEnabledFeatures        : nil
      )

    vkCheck vkCreateDevice(
      Vk.physDev, unsafeAddr deviceCreateInfo, nil, addr Vk.device)

  block getQueue:
    vkGetDeviceQueue(Vk.device, Vk.queueIdx, 0, addr Vk.queue)
    assert not isNullHandle(Vk.queue)

  # TODO
  false


proc destroyVulkan() =
  if not isNullHandle(Vk.device):
    echo "Destroying VkDevice"
    vkCheck vkDeviceWaitIdle(Vk.device)
    vkDestroyDevice(Vk.device, nil)

  if not isNullHandle(Vk.instance):
    echo "Destroying VkInstance"
    vkDestroyInstance(Vk.instance, nil)


proc main() =
  assert glfwInit()

  glfwWindowHint(GlfwContextVersionMajor, 3)
  glfwWindowHint(GlfwContextVersionMinor, 3)
  glfwWindowHint(GlfwResizable, GLFW_FALSE)

  let w: GLFWWindow = glfwCreateWindow(1280, 720, "EEEEEE")
  if w == nil: quit(-1)

  discard w.setKeyCallback(keyEventCallback)
  w.makeContextCurrent()

  doAssert initVulkan()

  # No main loop yet

  destroyVulkan()

when isMainModule:
  main()
