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

    integer :: i, j, k, ii, jj, kk, n
    real(dp) :: start_time, end_time, start_loop_time, end_loop_time, mean_loop_time
    real(dp), allocatable :: module_load_durations(:), module_delete_durations(:), tensor_creation_durations(:)
    real(dp), allocatable :: tensor_deletion_durations(:), inference_durations(:), all_durations(:,:)
    character(len=50), allocatable :: messages(:)

    integer, parameter :: I_MAX=128, J_MAX=64, K_MAX=40
    real(wp), parameter :: PI = 4.0 * ATAN(1.0)
    real(wp), parameter :: RADIAN = 180.0 / PI

    real(wp), dimension(:,:,:), allocatable, target :: uuu, vvv, gwfcng_x, gwfcng_y
    real(wp), dimension(:,:,:), allocatable :: gwfcng_x_ref, gwfcng_y_ref
    real(wp), dimension(:,:), allocatable, target :: lat, psfc

    real(wp), dimension(:,:), allocatable, target :: uuu_flattened, vvv_flattened
    real(wp), dimension(:,:), allocatable, target :: lat_reshaped, psfc_reshaped
    real(wp), dimension(:,:), allocatable, target  :: gwfcng_x_flattened, gwfcng_y_flattened

    integer(c_int), parameter :: n_inputs = 3

    ! Shape is the shape of the tensor we want to go into the torch
    ! Stride is the mapping between the underlying data and the array
    integer(c_int), parameter :: dims_2D = 2
    integer(c_int64_t) :: shape_2D(dims_2D) = [I_MAX*J_MAX, K_MAX]
    integer(c_int) :: stride_2D(dims_2D) = [1,2]
    integer(c_int), parameter :: dims_1D = 2
    integer(c_int64_t) :: shape_1D(dims_1D) = [I_MAX*J_MAX, 1]
    integer(c_int) :: stride_1D(dims_1D) = [1,2]
    integer(c_int), parameter :: dims_out = 2
    integer(c_int64_t) :: shape_out(dims_out) = [I_MAX*J_MAX, K_MAX]
    integer(c_int) :: stride_out(dims_out) = [1,2]

    character(len=:), allocatable :: model_dir, model_name
    character(len=128) :: msg1, msg2, msg3, msg4
    integer :: ntimes

    type(torch_module) :: model
    type(torch_tensor), dimension(n_inputs) :: in_tensors
    type(torch_tensor) :: gwfcng_x_tensor, gwfcng_y_tensor

    print *, "====== DIRECT COUPLED ======"

    call setup(model_dir, model_name, ntimes, n)

    allocate(module_load_durations(ntimes))
    allocate(module_delete_durations(ntimes))
    allocate(tensor_creation_durations(ntimes))
    allocate(tensor_deletion_durations(ntimes))
    allocate(inference_durations(ntimes))
    allocate(all_durations(ntimes, 5))
    allocate(messages(5))

    ! Read gravity wave parameterisation data in from file
    allocate(uuu(I_MAX, J_MAX, K_MAX))
    allocate(vvv(I_MAX, J_MAX, K_MAX))
    allocate(gwfcng_x(I_MAX, J_MAX, K_MAX))
    allocate(gwfcng_y(I_MAX, J_MAX, K_MAX))
    allocate(lat(I_MAX, J_MAX))
    allocate(psfc(I_MAX, J_MAX))

    ! flatten data (nlat, nlon, n) --> (nlat*nlon, n)
    allocate( uuu_flattened(I_MAX*J_MAX, K_MAX) )
    allocate( vvv_flattened(I_MAX*J_MAX, K_MAX) )
    allocate( lat_reshaped(I_MAX*J_MAX, 1) )
    allocate( psfc_reshaped(I_MAX*J_MAX, 1) )
    allocate( gwfcng_x_flattened(I_MAX*J_MAX, K_MAX) )
    allocate( gwfcng_y_flattened(I_MAX*J_MAX, K_MAX) )

    ! Read in saved input (and output) values
    open(10, file='../cgdrag_model/uuu.txt')
    open(11, file='../cgdrag_model/vvv.txt')
    open(12, file='../cgdrag_model/lat.txt')
    open(13, file='../cgdrag_model/psfc.txt')

    do i = 1, I_MAX
      do j = 1, J_MAX
          do k = 1, K_MAX
              read(10, '(3(I4, 1X), E25.16)') ii, jj, kk, uuu(ii,jj,kk)
              read(11, '(3(I4, 1X), E25.16)') ii, jj, kk, vvv(ii,jj,kk)
          end do
          read(12, '(2(I4, 1X), E25.16)') ii, jj, lat(ii,jj)
          read(13, '(2(I4, 1X), E25.16)') ii, jj, psfc(ii,jj)
      end do
    end do

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

  ! Initialise timings with arbitrary large values
    module_load_durations(:) = 100.
    module_delete_durations(:) = 100.
    tensor_creation_durations(:) = 100.
    tensor_deletion_durations(ntimes) = 100.
    inference_durations(ntimes) = 100.
    all_durations(:, :) = 100.
    start_loop_time = 1000.
    end_loop_time = 3000.
    start_time = 1000.
    end_time = 3000.

    if (ntimes .lt. 2) then
      write(*,*) "Error: ntimes must be at least 2"
      return
    end if

    ! Load model (creation/deletion timed at end)
    model = torch_module_load(model_dir//"/"//model_name)

    do j=1,J_MAX
        uuu_flattened((j-1)*I_MAX+1:j*I_MAX,:) = uuu(:,j,:)
        vvv_flattened((j-1)*I_MAX+1:j*I_MAX,:) = vvv(:,j,:)
        lat_reshaped((j-1)*I_MAX+1:j*I_MAX, 1) = lat(:,j)*RADIAN
        psfc_reshaped((j-1)*I_MAX+1:j*I_MAX, 1) = psfc(:,j)
    end do

    do i = 1, ntimes
      if (i==2) then
        start_loop_time = omp_get_wtime()
      end if

      ! Create input and output tensors for the model.
      ! ------------------------------ Start tensor creation timer ------------------------------
      start_time = omp_get_wtime()
      in_tensors(3) = torch_tensor_from_blob(c_loc(lat_reshaped), dims_1D, shape_1D, torch_wp, torch_kCPU, stride_1D)
      in_tensors(2) = torch_tensor_from_blob(c_loc(psfc_reshaped), dims_1D, shape_1D, torch_wp, torch_kCPU, stride_1D)

      ! Zonal
      in_tensors(1) = torch_tensor_from_blob(c_loc(uuu_flattened), dims_2D, shape_2D, torch_wp, torch_kCPU, stride_2D)
      gwfcng_x_tensor = torch_tensor_from_blob(c_loc(gwfcng_x_flattened), dims_out, shape_out, torch_wp, torch_kCPU, stride_out)
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
      in_tensors(1) = torch_tensor_from_blob(c_loc(vvv_flattened), dims_2D, shape_2D, torch_wp, torch_kCPU, stride_2D)
      gwfcng_y_tensor = torch_tensor_from_blob(c_loc(gwfcng_y_flattened), dims_out, shape_out, torch_wp, torch_kCPU, stride_out)
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

      ! Reshape, and assign to gwfcng
      do j=1,J_MAX
        gwfcng_x(:,j,:) = gwfcng_x_flattened((j-1)*I_MAX+1:j*I_MAX,:)
        gwfcng_y(:,j,:) = gwfcng_y_flattened((j-1)*I_MAX+1:j*I_MAX,:)
      end do

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

      write(msg1, '(A, I10, A, F10.3, A)') "check iteration create tensors", i, " (", tensor_creation_durations(i), " s)"
      write(msg2, '(A, I15, A, F10.3, A)') "check iteration inference", i, " (", inference_durations(i), " s)"
      write(msg3, '(A, I10, A, F10.3, A)') "check iteration delete tensors", i, " (", tensor_deletion_durations(i), " s)"
      print *, trim(msg1)
      print *, trim(msg2)
      print *, trim(msg3)
    end do

    end_loop_time = omp_get_wtime()
    mean_loop_time = (end_loop_time - start_loop_time)/(ntimes - 1)
    write(msg4, '(A, I1, A, F24.4, A)') "Mean time for ", ntimes, " loops", mean_loop_time, " s"
    print *, trim(msg4)

    call time_module(ntimes, model_dir, model_name, module_load_durations, module_delete_durations)

    all_durations(:, 1) = module_load_durations
    all_durations(:, 2) = module_delete_durations
    all_durations(:, 3) = tensor_creation_durations
    all_durations(:, 4) = tensor_deletion_durations
    all_durations(:, 5) = inference_durations
    messages = [character(len=20) :: "module creation", "module deletion", "tensor creation", "tensor deletion", "forward pass"]
    call print_all_time_stats(all_durations, messages)

    deallocate(module_load_durations)
    deallocate(module_delete_durations)
    deallocate(tensor_creation_durations)
    deallocate(tensor_deletion_durations)
    deallocate(inference_durations)
    deallocate(all_durations)
    deallocate(messages)
    deallocate(uuu)
    deallocate(vvv)
    deallocate(gwfcng_x)
    deallocate(gwfcng_y)
    deallocate(lat)
    deallocate(psfc)
    deallocate(uuu_flattened)
    deallocate(vvv_flattened)
    deallocate(lat_reshaped)
    deallocate(psfc_reshaped)
    deallocate(gwfcng_x_flattened)
    deallocate(gwfcng_y_flattened)
    deallocate(gwfcng_x_ref)
    deallocate(gwfcng_y_ref)

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


end program benchmark_cgdrag_test
