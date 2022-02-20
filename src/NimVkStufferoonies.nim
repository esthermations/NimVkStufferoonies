import nimgl/[glfw, vulkan]
from bitops import bitand

# Const values that nimgl/vulkan *should* have in it but doesn't for some reason.
let
  VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR = cast[VkStructureType](1000001000)

proc keyEventCallback(window: GLFWWindow, key, scancode, action, mods: int32) {.cdecl.} =
  if action == GLFWPress:
    if key == GLFWKey.ESCAPE:
      window.setWindowShouldClose(true)


template vkCheck(result: VkResult): untyped =
  if result != VK_SUCCESS:
    echo "vkCheck: ", $result
    doAssert result == VK_SUCCESS


template vkHasBits(value, mask: untyped): bool =
  bitand(uint32(value), uint32(mask)) == uint32(mask)


template isNullHandle(handle: untyped): bool =
  VkHandle(handle) == VkHandle(0)


type
  VulkanSemaphores = object
    imageAvailable : VkSemaphore
    renderFinished : VkSemaphore

  VulkanState = object
    window     : GLFWWindow
    device     : VkDevice
    instance   : VkInstance
    surface    : VkSurfaceKHR
    surfaceCapabilities : VkSurfaceCapabilitiesKHR
    physDev    : VkPhysicalDevice
    queueIdx   : uint32
    queue      : VkQueue # Graphics and present on the same queue for now
    cmdPool    : VkCommandPool
    swapchain  : VkSwapchainKHR
    semaphores : VulkanSemaphores

# My global renderer state variable. Could arguably choose a better name -- in
# Intel's "API Without Secrets" tutorial they just use the name "Vulkan". So
# this doesn't seem too bad.
var Vk : VulkanState


# Forward decls, which for some sad reason are necessary in the year of our
# lord 2022
proc initVulkan(): bool
proc destroyVulkan()


proc main() =
  assert glfwInit()

  glfwWindowHint(GlfwContextVersionMajor, 3)
  glfwWindowHint(GlfwContextVersionMinor, 3)
  glfwWindowHint(GlfwClientApi, GlfwNoApi)
  glfwWindowHint(GlfwResizable, GlFw_FaLsE)

  let w: GLFWWindow = glfwCreateWindow(1280, 720, "EEEEEE")
  if w == nil: quit(-1)

  discard w.setKeyCallback(keyEventCallback)
  w.makeContextCurrent()

  doAssert initVulkan()

  # No main loop yet

  destroyVulkan()


proc initVulkan(): bool =
  # I usually get these names via macros like VK_KHR_SWAPCHAIN_EXTENSION_NAME
  # in C++ but those don't seem to be defined in nimgl. So I'm just running
  # 'vulkaninfo' on my local machine and putting the strings from that in here.

  assert glfwVulkanSupported()

  doAssert vkInit(load1_0 = true, load1_1 = true)

  var
    requiredInstanceExtensions = @[ "VK_EXT_debug_utils" ]
    requiredLayers             = @[ "VK_LAYER_KHRONOS_validation" ]

    numGlfwInstanceExtensions : uint32 = 0

  let
    glfwInstanceExtensions    : cstringArray
      = glfwGetRequiredInstanceExtensions(addr numGlfwInstanceExtensions)

  for i in 0 ..< numGlfwInstanceExtensions:
    let ext = $glfwInstanceExtensions[i]
    echo "GLFW requires extension: ", ext
    requiredInstanceExtensions.add ext

  # deallocCStringArray glfwInstanceExtensions

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
  echo "Created VkInstance"

  Vk.window  = glfwCreateWindow(1920, 1080, cstring("Hello"))
  vkCheck glfwCreateWindowSurface(Vk.instance, Vk.window, nil, addr Vk.surface)

  var
    physicalDevices    : seq[VkPhysicalDevice]
    numPhysicalDevices : uint32 = 0

  vkCheck vkEnumeratePhysicalDevices(Vk.instance, addr numPhysicalDevices, nil)
  physicalDevices.setLen numPhysicalDevices
  vkCheck vkEnumeratePhysicalDevices(
    Vk.instance, addr numPhysicalDevices, addr physicalDevices[0])

  const requiredDeviceExtensions = @[
    "VK_KHR_swapchain",
    "VK_KHR_maintenance1",
    "VK_EXT_robustness2"
  ]

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
  echo "Created VkPhysicalDevice"

  loadVK_KHR_surface()
  loadVK_KHR_swapchain()

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

    for i in 0 ..< numQueueFamilies:
      var supportsPresent: VkBool32 = VkBool32(VK_FALSE)
      vkCheck vkGetPhysicalDeviceSurfaceSupportKHR(Vk.physDev, i, Vk.surface, addr supportsPresent)

      let
        props              = queueFamilyProps[i]
        hasQueuesAvailable = props.queueCount > 0
        hasGraphicsQueue   = vkHasBits(props.queueFlags, VK_QUEUE_GRAPHICS_BIT)

      echo "VkDeviceQueue: Queue ", $i, ": hasQueuesAvailable = ", $hasQueuesAvailable, ", hasGraphicsQueue = ", $hasGraphicsQueue

      if hasQueuesAvailable and hasGraphicsQueue and uint32(supportsPresent) == uint32(VK_TRUE):
        Vk.queueIdx = i
        break selectQueueFamily

  assert Vk.queueIdx != high(uint32)
  echo "VkDeviceQueue: Using queue family id ", $Vk.queueIdx

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

  echo "Created VkDevice"

  block getQueue:
    vkGetDeviceQueue(Vk.device, Vk.queueIdx, 0, addr Vk.queue)
    assert not isNullHandle(Vk.queue)

  block createSemaphores:
    let createInfo = VkSemaphoreCreateInfo(
      sType : VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
      pNext : nil,
      flags : VkSemaphoreCreateFlags(0),
    )

    vkCheck vkCreateSemaphore(Vk.device, unsafeAddr createInfo, nil, addr Vk.semaphores.imageAvailable)
    vkCheck vkCreateSemaphore(Vk.device, unsafeAddr createInfo, nil, addr Vk.semaphores.renderFinished)

  block createSwapchain:

    block getSurfaceCapabilities:
      vkCheck vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
        Vk.physDev,
        Vk.surface,
        addr Vk.surfaceCapabilities
      )
      echo "Got surface capabilities: ", $Vk.surfaceCapabilities

    var numFormats : uint32 = 0

    vkCheck vkGetPhysicalDeviceSurfaceFormatsKHR(Vk.physDev, Vk.surface, addr numFormats, nil)
    assert numFormats > 0

    var availableFormats = newSeq[VkSurfaceFormatKHR](numFormats)

    vkCheck vkGetPhysicalDeviceSurfaceFormatsKHR(Vk.physDev, Vk.surface, addr numFormats, addr availableFormats[0])
    assert availableFormats.len > 0

    echo "Got available formats"

    var createInfo = VkSwapchainCreateInfoKHR(
      sType                 : VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
      pNext                 : nil,
      flags                 : VkSwapchainCreateFlagsKHR(0),
      surface               : Vk.surface,
      minImageCount         : Vk.surfaceCapabilities.maxImageCount,
      imageFormat           : availableFormats[0].format, # Just use the first one...
      imageColorSpace       : availableFormats[0].colorSpace,
      imageExtent           : Vk.surfaceCapabilities.minImageExtent,
      imageArrayLayers      : 1,
      imageUsage            : VkImageUsageFlags(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT),
      imageSharingMode      : VK_SHARING_MODE_EXCLUSIVE,
      queueFamilyIndexCount : 0,
      pQueueFamilyIndices   : nil,
      compositeAlpha        : VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
      presentMode           : VK_PRESENT_MODE_FIFO_KHR,
      clipped               : VkBool32(VK_TRUE)
    )

    vkCheck vkCreateSwapchainKHR(
      Vk.device,
      addr createInfo,
      nil,
      addr Vk.swapchain
    )

  # TODO:
  #   - [x] Create semaphores for image available and rendering complete
  #   - [ ] Create swapchain with all its images and whatnot
  #   - [ ] Allocate command buffers
  #   - [ ] Write some simple shaders
  #   - [ ] Draw a funglermubffllausenfeeeeeere triangle!!!
  #
  # And maybe:
  #   - [ ] Refactor init/destruct code into a constructor+destructor.
  #         See: https://nim-lang.org/docs/destructors.html
  true


proc destroyVulkan() =

  if not isNullHandle(Vk.semaphores.imageAvailable):
    echo "Destroying VkSemaphore ImageAvailable"
    vkDestroySemaphore(Vk.device, Vk.semaphores.imageAvailable, nil)

  if not isNullHandle(Vk.semaphores.renderFinished):
    echo "Destroying VkSemaphore RenderFinished"
    vkDestroySemaphore(Vk.device, Vk.semaphores.renderFinished, nil)

  if not isNullHandle(Vk.device):
    echo "Destroying VkDevice"
    vkCheck vkDeviceWaitIdle(Vk.device)
    vkDestroyDevice(Vk.device, nil)

  if not isNullHandle(Vk.surface):
    echo "Destroying VkSurfaceKHR"
    vkDestroySurfaceKHR(Vk.instance, Vk.surface, nil)

  if not isNullHandle(Vk.instance):
    echo "Destroying VkInstance"
    vkDestroyInstance(Vk.instance, nil)



when isMainModule:
  main()
