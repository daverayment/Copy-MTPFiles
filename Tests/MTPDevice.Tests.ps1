BeforeAll {
    $MyDeviceName = "Huawei P30 Pro"
    Import-Module .\MTPDevice.psm1
}

Describe "MTPDevice Module - Attached Device" {
    It "Returns null if the DeviceName does not match." {
        Get-TargetDevice -DeviceName "NonexistentDevice" | Should -BeNullOrEmpty
    }

    It "Returns the matching device if the DeviceName matches." {
        $device = Get-TargetDevice -DeviceName $MyDeviceName
        $device | Should -Not -BeNullOrEmpty
        $device.Name | Should -Be $MyDeviceName
    }

    It "Returns the single attached device if no DeviceName is specified." {
        $device = Get-MTPDevice
        $device | Should -Not -BeNullOrEmpty
        $device.Name | Should -Be $MyDeviceName
    }
}
