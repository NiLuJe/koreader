describe("AutoSuspend", function()
    setup(function()
        require("commonrequire")
        package.unloadAll()
        require("document/canvascontext"):init(require("device"))
    end)

    describe("suspend", function()
        before_each(function()
            local Device = require("device")
            stub(Device, "isKobo")
            Device.isKobo.returns(true)
            Device.input.waitEvent = function() end
            local UIManager = require("ui/uimanager")
            stub(UIManager, "suspend")
            UIManager._run_forever = true
            G_reader_settings:saveSetting("auto_suspend_timeout_seconds", 10)
            require("mock_time"):install()
            -- Reset UIManager:getTime()
            UIManager:handleInput()
        end)

        after_each(function()
            require("device").isKobo:revert()
            require("ui/uimanager").suspend:revert()
            G_reader_settings:delSetting("auto_suspend_timeout_seconds")
            require("mock_time"):uninstall()
        end)

        it("should be able to execute suspend when timing out", function()
            local mock_time = require("mock_time")
            local widget_class = dofile("plugins/autosuspend.koplugin/main.lua")
            local widget = widget_class:new() --luacheck: ignore
            local UIManager = require("ui/uimanager")
            mock_time:increase(5)
            UIManager:handleInput()
            assert.stub(UIManager.suspend).was.called(0)
            mock_time:increase(6)
            UIManager:handleInput()
            assert.stub(UIManager.suspend).was.called(1)
        end)

        it("should be able to deprecate last task", function()
            local mock_time = require("mock_time")
            local widget_class = dofile("plugins/autosuspend.koplugin/main.lua")
            local widget = widget_class:new()
            mock_time:increase(5)
            local UIManager = require("ui/uimanager")
            UIManager:handleInput()
            assert.stub(UIManager.suspend).was.called(0)
            widget:onInputEvent()
            widget:onSuspend()
            widget:onResume()
            mock_time:increase(6)
            UIManager:handleInput()
            assert.stub(UIManager.suspend).was.called(0)
            mock_time:increase(5)
            UIManager:handleInput()
            assert.stub(UIManager.suspend).was.called(1)
        end)
    end)

    describe("shutdown", function()
        --- @todo duplicate with above, elegant way to DRY?
        before_each(function()
            local Device = require("device")
            stub(Device, "isKobo")
            Device.isKobo.returns(true)
            stub(Device, "canPowerOff")
            Device.canPowerOff.returns(true)
            Device.input.waitEvent = function() end
            local UIManager = require("ui/uimanager")
            stub(UIManager, "poweroff_action")
            UIManager._run_forever = true
            G_reader_settings:saveSetting("autoshutdown_timeout_seconds", 10)
            require("mock_time"):install()
            -- Reset UIManager:getTime()
            UIManager:handleInput()
        end)

        after_each(function()
            require("device").isKobo:revert()
            require("ui/uimanager").poweroff_action:revert()
            G_reader_settings:delSetting("autoshutdown_timeout_seconds")
            require("mock_time"):uninstall()
        end)

        it("should be able to execute suspend when timing out", function()
            local mock_time = require("mock_time")
            local widget_class = dofile("plugins/autosuspend.koplugin/main.lua")
            local widget = widget_class:new() --luacheck: ignore
            local UIManager = require("ui/uimanager")
            mock_time:increase(5)
            UIManager:handleInput()
            assert.stub(UIManager.poweroff_action).was.called(0)
            mock_time:increase(6)
            UIManager:handleInput()
            assert.stub(UIManager.poweroff_action).was.called(1)
        end)

        it("should be able to deprecate last task", function()
            local mock_time = require("mock_time")
            local widget_class = dofile("plugins/autosuspend.koplugin/main.lua")
            local widget = widget_class:new()
            mock_time:increase(5)
            local UIManager = require("ui/uimanager")
            UIManager:handleInput()
            assert.stub(UIManager.poweroff_action).was.called(0)
            widget:onInputEvent()
            widget:onSuspend()
            widget:onResume()
            mock_time:increase(6)
            UIManager:handleInput()
            assert.stub(UIManager.poweroff_action).was.called(0)
            mock_time:increase(5)
            UIManager:handleInput()
            assert.stub(UIManager.poweroff_action).was.called(1)
        end)
    end)
end)
