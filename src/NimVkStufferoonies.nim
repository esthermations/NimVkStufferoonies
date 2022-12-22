import nimgl/[glfw, vulkan]
from bitops import bitand

proc keyEventCallback(window: GLFWWindow, key, scancode, action, mods: int32) {.cdecl.} =
  if action == GLFWPress:
    if key == GLFWKey.ESCAPE:
      window.setWindowShouldClose(true)

template vkCheck(result: VkResult) =
  if result != VK_SUCCESS:
    echo "vkCheck: ", $result
    doAssert result == VK_SUCCESS

func vkHasBits[T1, T2](value: T1, mask: T2): bool =
  bitand(uint32(value), uint32(mask)) == uint32(mask)

func isNullHandle[T](handle: T): bool =
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
    semImageWritable : VkSemaphore
    semRenderDone    : VkSemaphore

# My global renderer state variable. Could arguably choose a better name -- in
# Intel's "API Without Secrets" tutorial they just use the name "Vulkan". So
# this doesn't seem too bad.
var vk : VulkanState

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
    requiredInstanceExtensions  = @[ "VK_EXT_debug_utils" ]
    requiredLayers: seq[string] = @[] # "VK_LAYER_KHRONOS_validation" ]

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

  vkCheck vkCreateInstance(unsafeAddr createInfo, nil, addr vk.instance)
  echo "Created VkInstance"

  vk.window  = glfwCreateWindow(1920, 1080, cstring("Hello"))
  vkCheck glfwCreateWindowSurface(vk.instance, vk.window, nil, addr vk.surface)

  var
    physicalDevices    : seq[VkPhysicalDevice]
    numPhysicalDevices : uint32 = 0

  vkCheck vkEnumeratePhysicalDevices(vk.instance, addr numPhysicalDevices, nil)
  physicalDevices.setLen numPhysicalDevices
  vkCheck vkEnumeratePhysicalDevices(
    vk.instance, addr numPhysicalDevices, addr physicalDevices[0])

  const requiredDeviceExtensions = @[ "VK_KHR_swapchain", "VK_KHR_maintenance1" ]

  block selectPhysicalDevice:
    for dev in physicalDevices:
      for ext in requiredDeviceExtensions:
        var
          props: VkPhysicalDeviceProperties
          feats: VkPhysicalDeviceFeatures

        vkGetPhysicalDeviceProperties(dev, addr props)
        vkGetPhysicalDeviceFeatures(dev, addr feats)

        # Probably all I care about... I reckon I'll use 1.2.182 or whatever
        # the latest stable release is.
        if vkVersionMajor(props.apiVersion) < 1: continue

        # Passed all checks, use this one
        vk.physDev = dev
        break selectPhysicalDevice

  assert not vk.physDev.isNullHandle
  echo "Created VkPhysicalDevice"

  loadVK_KHR_surface()
  loadVK_KHR_swapchain()

  block selectQueueFamily:
    vk.queueIdx = high(uint32)

    var numQueueFamilies: uint32
    vkGetPhysicalDeviceQueueFamilyProperties(
      vk.physDev, addr numQueueFamilies, nil)
    assert numQueueFamilies > 0

    var queueFamilyProps: seq[VkQueueFamilyProperties]
    queueFamilyProps.setLen numQueueFamilies
    vkGetPhysicalDeviceQueueFamilyProperties(
      vk.physDev, addr numQueueFamilies, addr queueFamilyProps[0])

    for i in 0 ..< numQueueFamilies:
      var supportsPresent: VkBool32 = VkBool32(VK_FALSE)
      vkCheck vkGetPhysicalDeviceSurfaceSupportKHR(vk.physDev, i, vk.surface, addr supportsPresent)

      let
        props              = queueFamilyProps[i]
        hasQueuesAvailable = props.queueCount > 0
        hasGraphicsQueue   = vkHasBits(props.queueFlags, VK_QUEUE_GRAPHICS_BIT)

      echo "VkDeviceQueue: Queue ", $i, ": hasQueuesAvailable = ", $hasQueuesAvailable, ", hasGraphicsQueue = ", $hasGraphicsQueue

      if hasQueuesAvailable and hasGraphicsQueue and uint32(supportsPresent) == uint32(VK_TRUE):
        vk.queueIdx = i
        break selectQueueFamily

  assert vk.queueIdx != high(uint32)
  echo "VkDeviceQueue: Using queue family id ", $vk.queueIdx

  block createQueue:
    let
      queuePriorities : array[1, float32] = [ 1.0f ]
      queueCreateInfo = VkDeviceQueueCreateInfo(
        sType            : VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        pNext            : nil,
        flags            : VkDeviceQueueCreateFlags(0),
        queueFamilyIndex : vk.queueIdx,
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
      vk.physDev, unsafeAddr deviceCreateInfo, nil, addr vk.device)

  echo "Created VkDevice"

  block getQueue:
    vkGetDeviceQueue(vk.device, vk.queueIdx, 0, addr vk.queue)
    assert not isNullHandle(vk.queue)

  # TODO:
  #   - [ ] Create semaphores for image available and rendering complete
  #   - [ ] Create swapchain with all its images and whatnot
  #   - [ ] Allocate command buffers
  #   - [ ] Write some simple shaders
  #   - [ ] Draw a funglermubffllausenfeeeeeere triangle!!!
  #
  # And maybe:
  #   - [ ] Refactor init/destruct code into a constructor+destructor.
  #         See: https://nim-lang.org/docs/destructors.html

  proc createSemaphore(): VkSemaphore =
    var info = VkSemaphoreCreateInfo(
      sType: VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
    )
    vkCheck vkCreateSemaphore(vk.device, addr info, nil, addr result)

  vk.semImageWritable = createSemaphore()
  vk.semRenderDone    = createSemaphore()

  echo "Created VkSemaphores"

  true


proc destroyVulkan() =
  if not isNullHandle vk.semImageWritable:
    echo "Destroying VkSemaphore - image writable"
    vkDestroySemaphore vk.device, vk.semImageWritable, nil

  if not isNullHandle vk.semRenderDone:
    echo "Destroying VkSemaphore - render done"
    vkDestroySemaphore vk.device, vk.semRenderDone, nil

  if not isNullHandle(vk.device):
    echo "Destroying VkDevice"
    vkCheck vkDeviceWaitIdle(vk.device)
    vkDestroyDevice(vk.device, nil)

  if not isNullHandle(vk.surface):
    echo "Destroying VkSurfaceKHR"
    vkDestroySurfaceKHR(vk.instance, vk.surface, nil)

  if not isNullHandle(vk.instance):
    echo "Destroying VkInstance"
    vkDestroyInstance(vk.instance, nil)



when isMainModule:
  main()
