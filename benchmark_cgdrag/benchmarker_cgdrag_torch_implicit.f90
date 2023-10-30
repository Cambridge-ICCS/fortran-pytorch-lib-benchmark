program benchmark_cgdrag_test

  use, intrinsic :: iso_c_binding
  use :: omp_lib, only : omp_get_wtime
  use :: utils, only : assert, setup, print_all_time_stats
  use :: ftorch
  use :: precision, only: dp

  implicit none

  ! Use double precision, rather than wp defined in precision module
  integer, parameter :: wp = dp
  integer, parameter :: torch_wp = torch_kFloat64

  call main()

  contains

    subroutine main()

      implicit none

      integer :: i, n, ii
      real(dp) :: start_time, end_time, start_loop_time, end_loop_time, mean_loop_time
      real(dp), dimension(:), allocatable :: module_load_durations, module_delete_durations, allocation_durations, deallocation_durations
      real(dp), dimension(:), allocatable :: tensor_creation_durations, tensor_deletion_durations, inference_durations
      real(dp), dimension(:,:), allocatable :: all_durations
      character(len=20), dimension(:), allocatable :: messages

      integer, parameter :: I_MAX=128, J_MAX=64, K_MAX=40

      real(wp), dimension(:,:,:), allocatable, target :: uuu, vvv, gwfcng_x, gwfcng_y
      real(wp), dimension(:,:,:), allocatable :: gwfcng_x_ref, gwfcng_y_ref
      real(wp), dimension(:,:), allocatable, target :: lat, psfc

      integer(c_int), parameter :: n_inputs = 3

      integer(c_int), parameter :: dims_1D = 2
      integer(c_int), parameter :: dims_2D = 2
      integer(c_int), parameter :: dims_out = 2
      integer(c_int64_t) :: shape_2D(dims_2D) = [I_MAX * J_MAX, K_MAX]
      integer(c_int) :: stride_2D(dims_2D) = [1, 2]
      integer(c_int64_t) :: shape_1D(dims_1D) = [I_MAX * J_MAX, 1]
      integer(c_int) :: stride_1D(dims_1D) = [1, 2]
      integer(c_int64_t) :: shape_out(dims_out) = [I_MAX * J_MAX, K_MAX]
      integer(c_int) :: stride_out(dims_out) = [1, 2]

      character(len=:), allocatable :: model_dir, model_name
      character(len=128) :: msg1, msg2, msg3, msg4, msg5, msg6
      integer :: ntimes

      type(torch_module) :: model
      type(torch_tensor), dimension(n_inputs) :: in_tensors
      type(torch_tensor) :: gwfcng_x_tensor, gwfcng_y_tensor

      print *, "====== DIRECT COUPLED ======"

      call setup(model_dir, model_name, ntimes, n)
      if (ntimes .lt. 2) then
        write(*, *) "Error: ntimes must be at least 2"
        return
      end if

      ! Allocate arrays shared with forpy implementation and read in data
      call init_common_arrays(ntimes, I_MAX, J_MAX, K_MAX, uuu, vvv, gwfcng_x, gwfcng_y, gwfcng_x_ref, gwfcng_y_ref, &
                              lat, psfc, module_load_durations, module_delete_durations, allocation_durations, deallocation_durations, &
                              tensor_creation_durations, tensor_deletion_durations, inference_durations, all_durations, messages, &
                              start_loop_time, end_loop_time, start_time, end_time)

      ! Load model (creation/deletion timed at end)
      model = torch_module_load(model_dir//"/"//model_name)

      do i = 1, ntimes

        if (i==2) then
          start_loop_time = omp_get_wtime()
        end if

        ! ------------------------------ Start allocation timer ----------------------------
        start_time = omp_get_wtime()
        end_time = omp_get_wtime()
        allocation_durations(i) = end_time - start_time
        ! ------------------------------ End allocation timer ----------------------------

        ! Create input and output tensors for the model.
        ! ------------------------------ Start tensor creation timer ------------------------------
        start_time = omp_get_wtime()
        in_tensors(3) = torch_tensor_from_blob(c_loc(lat), dims_1D, shape_1D, torch_wp, torch_kCPU, stride_1D)
        in_tensors(2) = torch_tensor_from_blob(c_loc(psfc), dims_1D, shape_1D, torch_wp, torch_kCPU, stride_1D)

        ! Zonal
        in_tensors(1) = torch_tensor_from_blob(c_loc(uuu), dims_2D, shape_2D, torch_wp, torch_kCPU, stride_2D)
        gwfcng_x_tensor = torch_tensor_from_blob(c_loc(gwfcng_x), dims_out, shape_out, torch_wp, torch_kCPU, stride_out)
        end_time = omp_get_wtime()
        tensor_creation_durations(i) = end_time - start_time
        ! ------------------------------ End tensor creation timer ------------------------------

        ! Run model and Infer
        ! ------------------------------ Start inference timer ------------------------------
        start_time = omp_get_wtime()
        call torch_module_forward(model, in_tensors, n_inputs, gwfcng_x_tensor)
        end_time = omp_get_wtime()
        inference_durations(i) = end_time - start_time
        ! ------------------------------ End inference timer ------------------------------

        ! Meridional
        ! ------------------------------ Start tensor creation timer ------------------------------
        start_time = omp_get_wtime()
        in_tensors(1) = torch_tensor_from_blob(c_loc(vvv), dims_2D, shape_2D, torch_wp, torch_kCPU, stride_2D)
        gwfcng_y_tensor = torch_tensor_from_blob(c_loc(gwfcng_y), dims_out, shape_out, torch_wp, torch_kCPU, stride_out)
        end_time = omp_get_wtime()
        tensor_creation_durations(i) = tensor_creation_durations(i) + (end_time - start_time)
        ! ------------------------------ End tensor creation timer ------------------------------

        ! Run model and Infer
        ! ------------------------------ Start inference timer ------------------------------
        start_time = omp_get_wtime()
        call torch_module_forward(model, in_tensors, n_inputs, gwfcng_y_tensor)
        end_time = omp_get_wtime()
        inference_durations(i) = inference_durations(i) + (end_time - start_time)
        ! ------------------------------ End inference timer ------------------------------

        ! Clean up.
        ! ------------------------------ Start tensor deletion timer ------------------------------
        start_time = omp_get_wtime()
        call torch_tensor_delete(gwfcng_y_tensor)
        call torch_tensor_delete(gwfcng_x_tensor)
        do ii = 1, n_inputs
          call torch_tensor_delete(in_tensors(ii))
        end do
        end_time = omp_get_wtime()
        tensor_deletion_durations(i) = end_time - start_time
        ! ------------------------------ End tensor deletion timer ------------------------------

        ! Check error
        call assert(gwfcng_x, gwfcng_x_ref, "Check x", rtol_opt=1.0e-8_wp)
        call assert(gwfcng_y, gwfcng_y_ref, "Check y", rtol_opt=1.0e-8_wp)

        ! ------------------------------ Start deallocation timer ------------------------------
        start_time = omp_get_wtime()
        end_time = omp_get_wtime()
        deallocation_durations(i) = end_time - start_time
        ! ------------------------------ End deallocation timer -----------------------------

        write(msg1, '(A, I18, A, F10.3, A)') "check iteration inference", i, " (", inference_durations(i), " s)"
        write(msg2, '(A, I13, A, F10.3, A)') "check iteration create tensors", i, " (", tensor_creation_durations(i), " s)"
        write(msg3, '(A, I13, A, F10.3, A)') "check iteration delete tensors", i, " (", tensor_deletion_durations(i), " s)"
        write(msg4, '(A, I12, A, F10.3, A)') "check iteration allocate arrays", i, " (", allocation_durations(i), " s)"
        write(msg5, '(A, I10, A, F10.3, A)') "check iteration deallocate arrays", i, " (", deallocation_durations(i), " s)"
        print *, trim(msg1)
        print *, trim(msg2)
        print *, trim(msg3)
        print *, trim(msg4)
        print *, trim(msg5)

      end do

      end_loop_time = omp_get_wtime()
      mean_loop_time = (end_loop_time - start_loop_time)/(ntimes - 1)
      write(msg6, '(A, I5, A, F24.4, A)') "Mean time for ", ntimes, " loops", mean_loop_time, " s"
      print *, trim(msg6)

      call time_module(ntimes, model_dir, model_name, module_load_durations, module_delete_durations)

      all_durations(:, 1) = module_load_durations
      all_durations(:, 2) = module_delete_durations
      all_durations(:, 3) = allocation_durations
      all_durations(:, 4) = deallocation_durations
      all_durations(:, 5) = tensor_creation_durations
      all_durations(:, 6) = tensor_deletion_durations
      all_durations(:, 7) = inference_durations
      messages = [character(len=20) :: "module creation", "module deletion", "array allocation", "array deallocation", "tensor creation", "tensor deletion", "forward pass"]
      call print_all_time_stats(all_durations, messages)

      call deallocate_common_arrays(module_load_durations, module_delete_durations, allocation_durations, deallocation_durations, &
                                    tensor_creation_durations, tensor_deletion_durations, inference_durations, all_durations, &
                                    messages, uuu, vvv, gwfcng_x, gwfcng_y, gwfcng_x_ref, gwfcng_y_ref, lat, psfc)

    end subroutine main

    subroutine time_module(ntimes, model_dir, model_name, module_load_durations, module_delete_durations)

      implicit none

      integer, intent(in) :: ntimes
      real(dp), dimension(:), intent(inout) :: module_load_durations, module_delete_durations
      integer :: i
      real(dp) :: start_time, end_time
      character(len=*), intent(in) :: model_dir, model_name
      type(torch_module) :: model

      do i = 1, ntimes
        ! ------------------------------ Start module load timer ------------------------------
        start_time = omp_get_wtime()
        model = torch_module_load(model_dir//"/"//model_name)
        end_time = omp_get_wtime()
        module_load_durations(i) = end_time - start_time
        ! ------------------------------ End module load timer ------------------------------

        ! ------------------------------ Start module deletion timer ------------------------------
        start_time = omp_get_wtime()
        call torch_module_delete(model)
        end_time = omp_get_wtime()
        module_delete_durations(i) = end_time - start_time
        ! ------------------------------ End module deletion timer ------------------------------
      end do

    end subroutine time_module

    subroutine init_common_arrays(ntimes, I_MAX, J_MAX, K_MAX, uuu, vvv, gwfcng_x, gwfcng_y, gwfcng_x_ref, gwfcng_y_ref, &
                                    lat, psfc, module_load_durations, module_delete_durations, allocation_durations, &
                                    deallocation_durations, tensor_creation_durations, tensor_deletion_durations, inference_durations, &
                                    all_durations, messages, start_loop_time, end_loop_time, start_time, end_time)

      implicit none

      integer, intent(in):: ntimes, I_MAX, J_MAX, K_MAX

      real(wp), intent(out), dimension(:,:,:), allocatable :: uuu, vvv, gwfcng_x, gwfcng_y
      real(wp), intent(out), dimension(:,:,:), allocatable :: gwfcng_x_ref, gwfcng_y_ref
      real(wp), intent(out), dimension(:,:), allocatable :: lat, psfc

      real(dp), intent(out), dimension(:), allocatable :: module_load_durations, module_delete_durations, allocation_durations, deallocation_durations
      real(dp), intent(out), dimension(:), allocatable :: tensor_creation_durations, tensor_deletion_durations, inference_durations
      real(dp), intent(out), dimension(:,:), allocatable :: all_durations
      character(len=20), intent(out), dimension(:), allocatable :: messages

      real(dp), intent(out) :: start_loop_time, end_loop_time, start_time, end_time

      real(wp), parameter :: PI = 4.0 * ATAN(1.0)
      real(wp), parameter :: RADIAN = 180.0 / PI

      integer :: i, j, k, ii, jj, kk

      ! Read gravity wave parameterisation data in from file
      allocate(uuu(I_MAX, J_MAX, K_MAX))
      allocate(vvv(I_MAX, J_MAX, K_MAX))
      allocate(gwfcng_x(I_MAX, J_MAX, K_MAX))
      allocate(gwfcng_y(I_MAX, J_MAX, K_MAX))
      allocate(lat(I_MAX, J_MAX))
      allocate(psfc(I_MAX, J_MAX))

      ! Read in saved input (and output) values
      open(10, file='../cgdrag_model/uuu.txt')
      open(11, file='../cgdrag_model/vvv.txt')
      open(12, file='../cgdrag_model/lat.txt')
      open(13, file='../cgdrag_model/psfc.txt')

      do i = 1, I_MAX
        do j = 1, J_MAX
          do k = 1, K_MAX
            read(10, '(3(I4, 1X), E25.16)') ii, jj, kk, uuu(ii, jj, kk)
            read(11, '(3(I4, 1X), E25.16)') ii, jj, kk, vvv(ii, jj, kk)
            end do
          read(12, '(2(I4, 1X), E25.16)') ii, jj, lat(ii, jj)
          read(13, '(2(I4, 1X), E25.16)') ii, jj, psfc(ii, jj)
        end do
      end do

      lat = lat * RADIAN

      ! Read in reference data
      allocate(gwfcng_x_ref(I_MAX, J_MAX, K_MAX))
      allocate(gwfcng_y_ref(I_MAX, J_MAX, K_MAX))
      open(14,file="../cgdrag_model/forpy_reference_x.txt")
      open(15,file="../cgdrag_model/forpy_reference_y.txt")
      read(14,*) gwfcng_x_ref
      read(15,*) gwfcng_y_ref

      close(10)
      close(11)
      close(12)
      close(13)
      close(14)
      close(15)

      ! Allocate arrays for timings
      allocate(module_load_durations(ntimes))
      allocate(module_delete_durations(ntimes))
      allocate(allocation_durations(ntimes))
      allocate(deallocation_durations(ntimes))
      allocate(tensor_creation_durations(ntimes))
      allocate(tensor_deletion_durations(ntimes))
      allocate(inference_durations(ntimes))
      allocate(all_durations(ntimes, 7))
      allocate(messages(5))

      ! Initialise timings with arbitrary large values
      module_load_durations(:) = 100.
      module_delete_durations(:) = 100.
      allocation_durations(:) = 100.
      deallocation_durations(:) = 100.
      tensor_creation_durations(:) = 100.
      tensor_deletion_durations(ntimes) = 100.
      inference_durations(ntimes) = 100.
      all_durations(:, :) = 100.
      start_loop_time = 1000.
      end_loop_time = 3000.
      start_time = 1000.
      end_time = 3000.

    end subroutine init_common_arrays

    subroutine deallocate_common_arrays(module_load_durations, module_delete_durations, allocation_durations, &
                                        deallocation_durations, tensor_creation_durations, tensor_deletion_durations, &
                                        inference_durations, all_durations, messages, uuu, vvv, gwfcng_x, gwfcng_y, &
                                        gwfcng_x_ref, gwfcng_y_ref, lat, psfc)

      implicit none

      real(dp), intent(inout), dimension(:), allocatable :: module_load_durations, module_delete_durations, allocation_durations, deallocation_durations
      real(dp), intent(inout), dimension(:), allocatable :: tensor_creation_durations, tensor_deletion_durations, inference_durations
      real(dp), intent(inout), dimension(:,:), allocatable :: all_durations
      character(len=20), intent(inout), dimension(:), allocatable :: messages

      real(wp), intent(inout), dimension(:,:,:), allocatable :: uuu, vvv, gwfcng_x, gwfcng_y
      real(wp), intent(inout), dimension(:,:,:), allocatable :: gwfcng_x_ref, gwfcng_y_ref
      real(wp), intent(inout), dimension(:,:), allocatable :: lat, psfc

      deallocate(module_load_durations)
      deallocate(module_delete_durations)
      deallocate(allocation_durations)
      deallocate(deallocation_durations)
      deallocate(tensor_creation_durations)
      deallocate(tensor_deletion_durations)
      deallocate(inference_durations)
      deallocate(all_durations)
      deallocate(messages)
      deallocate(uuu)
      deallocate(vvv)
      deallocate(gwfcng_x)
      deallocate(gwfcng_y)
      deallocate(gwfcng_x_ref)
      deallocate(gwfcng_y_ref)
      deallocate(lat)
      deallocate(psfc)

    end subroutine deallocate_common_arrays

end program benchmark_cgdrag_test
